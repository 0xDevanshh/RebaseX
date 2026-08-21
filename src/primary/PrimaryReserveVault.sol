// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PrimaryReserveVault
/// @notice Holds the stable reserve backing 1:1 primary-market redemptions.
/// @dev ================ WHY THIS IS A SEPARATE CONTRACT ================
///      This vault exists as its own contract, rather than as storage inside
///      PrimaryVenueAdapter, for one specific and structural reason: so the
///      adapter can satisfy the SettlementEngine's uniform "an adapter retains
///      nothing" invariant.
///
///      The engine enforces that invariant identically for every venue — see
///      {SettlementEngine} STEP 5 (the adapter consumed exactly the funded
///      delta) and STEP 10 (the engine retained nothing). On a BUY, `assetIn`
///      is the stable: the engine snapshots `balanceOf(adapter)` BEFORE
///      funding, funds the adapter, and then requires the adapter's stable
///      balance to have returned to exactly that snapshot. Any stable the
///      adapter still holds afterwards is `AdapterRetainedFunds`.
///
///      A primary market, however, must hold reserve SOMEWHERE — that is what
///      makes redemption at par possible at all. If the adapter itself were
///      that somewhere, then every buy would leave the adapter holding the
///      stable it had just been funded with, and EVERY BUY SETTLEMENT WOULD
///      REVERT. The reserve and the retains-nothing invariant cannot occupy
///      the same address.
///
///      So this vault is that "somewhere", and it sits OUTSIDE the
///      venue-adapter boundary the engine reasons about. The engine never
///      snapshots it, never asserts against it, and does not know it exists.
///      The adapter forwards stable here on a buy and pulls stable from here
///      on a sell, ending each settlement flat — which is exactly what the
///      engine demands of every other venue too.
///
///      The alternative — special-casing the primary venue in the engine so
///      the retains-nothing check does not apply to it — was rejected. It
///      would put a per-venue exemption inside the one check that makes every
///      adapter accountable, and the value of that check comes precisely from
///      its being uniform. Moving the reserve out of the adapter keeps the
///      engine's invariant unconditional.
///      ==================================================================
///
///      ==================== SECURITY MODEL ====================
///      No ReentrancyGuard. The only external calls made here are to `stable`,
///      which is fixed at construction and immutable. Both privileged entry
///      points are role-gated, and each performs its checks against a balance
///      read in the same call, so there is no cross-call state for a reentrant
///      caller to observe mid-update. A malicious or callback-bearing `stable`
///      could reenter, but it is trusted by construction — a stable that can
///      call back arbitrarily can already move this vault's entire balance
///      directly, and no guard here would change that.
///
///      No `to != address(0)` check on the withdrawal paths. A conforming
///      ERC-20 rejects a transfer to the zero address itself (OpenZeppelin
///      reverts `ERC20InvalidReceiver`), and both withdrawal functions are
///      reachable only by a held role, so a zero recipient is a privileged
///      caller's own bug rather than an attack surface. {ZeroAddress} is
///      enforced where it is not recoverable: the constructor, where a zero
///      `stable` or zero `admin` would deploy a permanently unusable vault.
///      ========================================================
contract PrimaryReserveVault is AccessControl {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice May pull reserve out via {withdrawTo}.
    /// @dev Granted to PrimaryVenueAdapter AFTER deployment, not in the
    ///      constructor. The adapter needs this vault's address to be
    ///      constructed, so the two cannot be wired in a single transaction;
    ///      granting the role as an explicit follow-up step also makes the
    ///      trust relationship visible in the deployment transcript rather
    ///      than implicit in a constructor argument.
    bytes32 public constant ADAPTER_ROLE = keccak256("ADAPTER_ROLE");

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The stable asset this vault holds as reserve.
    /// @dev Immutable. The SECURITY MODEL note above trusts this specific
    ///      token not to reenter maliciously, so it must not be swappable
    ///      after deployment. A vault holding balances of token A cannot have
    ///      its accounting repointed at token B.
    IERC20 public immutable stable;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Floor below which {adminWithdraw} will not take the reserve.
    /// @dev ============ SCOPE — READ BEFORE RELYING ON THIS ============
    ///      THIS DOES EXACTLY ONE THING: {adminWithdraw} reverts if it would
    ///      take this vault's balance below this threshold. It is a floor on
    ///      ADMIN-INITIATED OUTFLOWS. That is the whole of it.
    ///
    ///      WHAT IT IS NOT, stated explicitly because the name invites the
    ///      wrong reading:
    ///
    ///        - It does NOT recapitalize the vault. It moves no funds, ever.
    ///        - It does NOT detect a reserve shortfall, and it does NOT
    ///          respond to one. In particular it neither observes nor reacts
    ///          to a shortfall caused by an upward corporate action inflating
    ///          the stable value of outstanding equity beyond the reserve held
    ///          here — see PrimaryVenueAdapter's `quote()` for that exposure.
    ///          A vault sitting below its buffer because the multiplier moved
    ///          is a vault in exactly the same state as before, as far as this
    ///          variable is concerned.
    ///        - It does NOT constrain {withdrawTo}. A settlement-driven pull by
    ///          the adapter is not an admin outflow and is not subject to this
    ///          floor; gating it here would revert live settlements rather than
    ///          protect anything.
    ///        - It does NOT trigger, size, or otherwise participate in a
    ///          deposit. It only constrains how much can subsequently be
    ///          withdrawn by an admin once reserve exists.
    ///
    ///      RECAPITALIZATION, if desired, HAPPENS ENTIRELY THROUGH
    ///      {adminDeposit} — an off-chain-triggered operator action this
    ///      contract exposes but does not automate, schedule, or require.
    ///      Someone or something off-chain must decide to call it.
    ///
    ///      Do not conflate "the vault has a minimum buffer" with "the vault
    ///      monitors and restores its own solvency". It does neither of the
    ///      latter two.
    ///      ==============================================================
    uint256 public minReserveBuffer;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The vault holds less than the requested amount.
    error InsufficientReserve();

    /// @notice An admin withdrawal would take the balance below {minReserveBuffer}.
    error BelowMinReserveBuffer();

    /// @notice A constructor argument was the zero address.
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve pulled by the adapter to fund a settlement.
    /// @dev Distinct from {AdminWithdrawn} on purpose: these two outflows have
    ///      different authorities, different constraints, and completely
    ///      different meanings to anyone auditing the reserve. Collapsing them
    ///      into one event would make settlement-driven flow indistinguishable
    ///      from operator flow in the log.
    event Withdrawn(address to, uint256 amount);

    /// @notice Reserve added by an admin.
    event AdminDeposited(uint256 amount);

    /// @notice Reserve removed by an admin.
    event AdminWithdrawn(address to, uint256 amount);

    /// @notice {minReserveBuffer} was set.
    event MinReserveBufferSet(uint256 newBuffer);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param stable_ The stable asset held as reserve.
    /// @param admin   Address granted DEFAULT_ADMIN_ROLE. ADAPTER_ROLE is NOT
    ///                granted here — see {ADAPTER_ROLE}.
    /// @dev `minReserveBuffer` is left at its default of 0, so a freshly
    ///      deployed vault imposes no floor on admin withdrawals until one is
    ///      set. Deliberate: a nonzero default would be a number this contract
    ///      invented rather than one an operator chose.
    constructor(IERC20 stable_, address admin) {
        if (address(stable_) == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();

        stable = stable_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          ADAPTER PATH: WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends `amount` of reserve to `to`. The adapter's path for
    ///         funding a primary redemption.
    /// @dev The explicit balance check exists to fail with a named error rather
    ///      than with whatever the stable's own transfer happens to revert
    ///      with. A caller — the adapter, mid-settlement — can then attribute
    ///      the failure to reserve exhaustion instead of guessing at an opaque
    ///      token revert.
    ///
    ///      NOT subject to {minReserveBuffer}. See the note on that variable:
    ///      the buffer constrains admin outflows only, and applying it here
    ///      would revert live settlements.
    /// @param to     Recipient of the reserve.
    /// @param amount Amount of stable to send.
    function withdrawTo(address to, uint256 amount) external onlyRole(ADAPTER_ROLE) {
        if (stable.balanceOf(address(this)) < amount) revert InsufficientReserve();

        stable.safeTransfer(to, amount);

        emit Withdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN: CAPITALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Pulls `amount` of stable from the caller into the reserve.
    /// @dev THE ONLY WAY RESERVE ENTERS THIS VAULT THROUGH A FUNCTION. It is
    ///      also the entire recapitalization mechanism — see the note on
    ///      {minReserveBuffer} for what that does and does not imply.
    ///
    ///      Takes from `msg.sender` rather than from an arbitrary `from`, so
    ///      the admin cannot use its role to spend a third party's standing
    ///      approval to this vault.
    ///
    ///      No post-transfer delta assertion. This vault's accounting is the
    ///      live `balanceOf` read and nothing else — it stores no shadow
    ///      balance that a fee-on-transfer stable could desynchronize. The
    ///      emitted `amount` is therefore the amount REQUESTED; with a
    ///      non-conforming stable, slightly less may have arrived, and
    ///      {reserveBalance} rather than this event is the authority on what
    ///      the vault holds.
    /// @param amount Amount of stable to deposit.
    function adminDeposit(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stable.safeTransferFrom(msg.sender, address(this), amount);

        emit AdminDeposited(amount);
    }

    /// @notice Removes `amount` of reserve, subject to {minReserveBuffer}.
    /// @dev ============ THE ORDER OF THESE CHECKS IS LOAD-BEARING ============
    ///      The balance-sufficiency check MUST come first and MUST be
    ///      explicit. It must not be left implied by the buffer check.
    ///
    ///      Why: arithmetic is checked in Solidity 0.8.x, and the panic fires
    ///      DURING EVALUATION of `balance - amount`, before the comparison
    ///      against the buffer ever executes. So a lone buffer check of the
    ///      form
    ///
    ///          if (balance - amount < minReserveBuffer) revert ...
    ///
    ///      would, for `amount > balance`, not revert with the intended error
    ///      at all — it would panic with `Panic(0x11)` (arithmetic
    ///      underflow/overflow) from inside the subtraction. Callers get an
    ///      opaque panic instead of {InsufficientReserve}, and a panic is
    ///      indistinguishable from a genuine implementation bug in this
    ///      contract, which is exactly the signal that should not be
    ///      counterfeited by ordinary user input.
    ///
    ///      Ordering it this way means every reachable failure of this function
    ///      is a named revert. That is asserted directly by
    ///      `testFuzz_AdminWithdrawNeverPanics`, which fuzzes `amount` across
    ///      the entire uint256 range.
    ///      ====================================================================
    ///
    ///      The buffer is compared against the balance AFTER this withdrawal,
    ///      not before, so the floor is on the resulting state. Withdrawing
    ///      down to exactly the buffer is permitted; the check is strict.
    /// @param to     Recipient of the reserve.
    /// @param amount Amount of stable to remove.
    function adminWithdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Cached: two reads of the same value within one call, with no external
        // call in between that could change it. Caching does not weaken the
        // ordering argument above — the sufficiency check still gates the
        // subtraction.
        uint256 balance = stable.balanceOf(address(this));

        // FIRST, and explicitly. See the ordering note above.
        if (amount > balance) revert InsufficientReserve();

        // Only now is this subtraction known not to underflow.
        if (balance - amount < minReserveBuffer) revert BelowMinReserveBuffer();

        stable.safeTransfer(to, amount);

        emit AdminWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN: CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the floor on admin-initiated outflows.
    /// @dev Deliberately unvalidated against the current balance. A buffer may
    ///      legitimately be set ABOVE what the vault currently holds — that is
    ///      an operator declaring a target they intend to fund — and rejecting
    ///      it would force the admin to deposit before being allowed to state
    ///      the policy. Setting it above the balance simply means
    ///      {adminWithdraw} reverts for every nonzero amount until the reserve
    ///      is topped up. Note it does NOT compel that top-up: see the note on
    ///      {minReserveBuffer}.
    /// @param newBuffer The new floor.
    function setMinReserveBuffer(uint256 newBuffer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minReserveBuffer = newBuffer;

        emit MinReserveBufferSet(newBuffer);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The reserve currently held.
    /// @dev A LIVE READ, not a stored figure. This vault deliberately keeps no
    ///      internal balance counter, so there is nothing that can drift out of
    ///      step with the token's own accounting — including when reserve
    ///      arrives by direct transfer rather than through {adminDeposit},
    ///      which is counted here exactly like any other balance.
    /// @return The vault's stable balance.
    function reserveBalance() external view returns (uint256) {
        return stable.balanceOf(address(this));
    }
}
