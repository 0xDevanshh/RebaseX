// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRebasingEquityToken} from "../interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../interfaces/IShareRegistry.sol";

/// @title MockRebasingEquityToken
/// @notice Mock BEP-20/ERC-20 compatible tokenised-equity token whose balances
///         rebase via a global multiplier, backed 1:1 by underlying share units
///         recorded in a {MockShareRegistry}.
/// @dev ====================== ACCOUNTING MODEL ======================
///      SHARES ARE THE CANONICAL UNIT. `_shares` and `_totalShares` are the only
///      quantities this contract stores about ownership. There is deliberately
///      NO mapping of token-denominated balances anywhere in this file.
///
///      Token balances are DERIVED VIEWS, recomputed on every read:
///
///          balanceOf(account) = shares(account) * multiplier / 1e18
///          totalSupply()      = totalShares()   * multiplier / 1e18
///
///      A CORPORATE ACTION CHANGES THE MULTIPLIER, NOT SHARE OWNERSHIP. Applying
///      one moves every derived balance simultaneously while leaving `_shares`
///      and `_totalShares` byte-for-byte identical. That is the property the
///      whole design exists to guarantee, and it is what makes settlement
///      correct across a dividend or split: a share is a claim, and a corporate
///      action restates what the claim is worth, never who holds it.
///
///      Why this matters: any system that stored token balances instead would
///      have to rewrite every holder's balance on every corporate action — O(n)
///      writes, and wrong the moment one is missed. Storing shares makes a
///      corporate action a single storage write that is exactly correct for all
///      holders at once.
///      ==============================================================
///
///      ======================== ROUNDING POLICY ======================
///      Conversions use integer division and therefore truncate. The rules:
///
///      1. A transfer ALWAYS CONSERVES SHARES. A token-denominated transfer
///         resolves the requested amount to a share quantity ONCE, then debits
///         and credits that SAME quantity. Shares are never created or
///         destroyed by transfer rounding.
///      2. Token-amount conversions round DOWN (in favour of the payer), so a
///         `transfer(amount)` may move slightly less value than `amount` when
///         the multiplier does not divide it cleanly. This is rounding dust.
///      3. Allowance debits for share-exact transfers round UP, so a spender can
///         never move more value than was approved.
///      4. `sum(balanceOf(holders)) <= totalSupply()` is expected and correct:
///         `balanceOf` floors per holder, `totalSupply` floors once over the
///         aggregate. The gap is dust, not value creation. Share sums are exact;
///         only the derived token views carry dust.
///      ==============================================================
///
///      =================== AMM / DEX INTEGRATION RULE ================
///      HARD REQUIREMENT: any integration must measure ACTUAL BALANCE DELTAS.
///      It must never assume that moving `amount` changes a balance by `amount`.
///
///      Two independent reasons, and the second is the one that cannot be fixed
///      by any choice of rounding policy in this contract:
///
///      1. `transfer(amount)` resolves `amount` to shares by flooring, so the
///         value actually moved can be up to `multiplier / 1e18` wei BELOW
///         `amount`. Bounded and tiny, but real.
///
///      2. `balanceOf` floors the recipient's TOTAL shares, so the recipient's
///         balance delta depends on the share remainder they already held. Move
///         exactly one share at multiplier 1.5e18 to an account holding one
///         share: its balance goes 1 -> 3, a delta of 2, for a share worth 1.5.
///         The delta matches neither the request nor the value moved. This is
///         intrinsic to floor-based derived balances — `transferShares` is exact
///         in SHARES, and still cannot promise an exact balance delta.
///
///      Consequence for PancakeSwap V2 specifically. A V2 pair measures input as
///      `balanceOf(pair) - reserve` and enforces the K invariant against it, so:
///
///        - `swapExactTokensForTokens` is UNSAFE: the router prices the output
///          from the REQUESTED amountIn, transfers, then demands that output.
///          `TransferHelper.safeTransferFrom` checks only the boolean return, so
///          a short transfer passes silently, the pair measures less input than
///          the output was priced for, and the swap reverts with `Pancake: K` —
///          non-deterministically, depending on whether `getAmountOut`'s own
///          flooring slack happens to absorb the missing wei.
///
///        - `swapExactTokensForTokensSupportingFeeOnTransferTokens` is SAFE: it
///          derives the output from the MEASURED delta, so the priced output and
///          the actual input can never disagree.
///
///      Integrators needing an exact quantity must use {transferShares} and
///      account in shares. {sharesToAmount} and {amountToShares} are exposed so
///      the shortfall can be computed up front rather than discovered on revert.
///
///      Separately, and worth stating because it is not this contract's bug to
///      fix: a positive rebase raises `balanceOf(pair)` without any swap, leaving
///      `reserve < balanceOf`. V2 lets anyone claim that difference via `skim()`,
///      or absorb it as free input on the next swap — so a dividend accruing to
///      pooled tokens leaks to arbitrageurs rather than to liquidity providers.
///      ==============================================================
///
///      ======================== SECURITY MODEL =======================
///      No ReentrancyGuard. The only external calls this contract makes are to
///      the share registry, which makes no external calls of its own and so has
///      no callback path back into this token. There is no concrete reentrancy
///      route to defend against, and a guard would cost storage and gas to
///      block a call pattern that cannot occur. If the registry is ever replaced
///      with one that calls out — to a real custodian adapter, an oracle, or a
///      hook — this argument dies with it and a guard must be reconsidered.
///
///      The registry address is immutable, so the trust assumption above cannot
///      be swapped out after deployment by an admin.
///
///      PRIMARY_ROLE and CORPORATE_ACTION_ROLE are held separately — see below.
///      ==============================================================
contract MockRebasingEquityToken is IRebasingEquityToken, AccessControl {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice May mint through the primary issuance path.
    /// @dev Held separately from CORPORATE_ACTION_ROLE on purpose. Compromise of
    ///      the minting authority must not also confer the power to restate every
    ///      holder's balance, and compromise of the corporate-action authority
    ///      must not also confer the power to issue new shares. Either alone is
    ///      damaging; together they would let one key inflate supply and then
    ///      paper over it by moving the multiplier.
    bytes32 public constant PRIMARY_ROLE = keccak256("PRIMARY_ROLE");

    /// @notice May move the global multiplier.
    bytes32 public constant CORPORATE_ACTION_ROLE = keccak256("CORPORATE_ACTION_ROLE");

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fixed-point scale for the multiplier. A multiplier of 1e18 is 1.0.
    uint256 public constant MULTIPLIER_SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Registry recording the underlying share units that back this token.
    /// @dev Immutable: the trust assumption in the SECURITY MODEL note above
    ///      depends on which registry this is, so it must not be swappable.
    IShareRegistry public immutable registry;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev THE canonical ownership record. Share-denominated, never token-denominated.
    mapping(address account => uint256) private _shares;

    /// @dev Sum of `_shares` over all holders.
    uint256 private _totalShares;

    /// @dev Global rebase multiplier, scaled by MULTIPLIER_SCALE.
    uint256 private _multiplier;

    /// @dev Token-denominated allowances. See {allowance} for the trade-off.
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    string private _name;
    string private _symbol;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param name_     Token name.
    /// @param symbol_   Token symbol.
    /// @param admin     Address granted DEFAULT_ADMIN_ROLE. PRIMARY_ROLE and
    ///                  CORPORATE_ACTION_ROLE are NOT granted here; admin must
    ///                  grant them explicitly so the separation is visible in
    ///                  the deployment transcript rather than implicit.
    /// @param registry_ Share registry backing this token. Must have this token
    ///                  registered before the first mint.
    constructor(string memory name_, string memory symbol_, address admin, IShareRegistry registry_) {
        if (admin == address(0)) revert ZeroAddress();
        if (address(registry_) == address(0)) revert ZeroAddress();

        _name = name_;
        _symbol = symbol_;
        registry = registry_;
        _multiplier = MULTIPLIER_SCALE;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-20 METADATA
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20Metadata
    function name() external view returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC20Metadata
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC20Metadata
    /// @dev 18, matching MULTIPLIER_SCALE so a multiplier of 1e18 means one share
    ///      displays as exactly one whole token.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////
                        DERIVED TOKEN-AMOUNT VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    /// @dev DERIVED, not stored: `shares(account) * multiplier / 1e18`, floored.
    function balanceOf(address account) public view returns (uint256) {
        return _toAmount(_shares[account]);
    }

    /// @inheritdoc IERC20
    /// @dev DERIVED, not stored. Floors once over the aggregate, which is why it
    ///      can exceed the sum of individually floored balances by dust.
    function totalSupply() public view returns (uint256) {
        return _toAmount(_totalShares);
    }

    /*//////////////////////////////////////////////////////////////
                          SHARE ACCOUNTING VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRebasingEquityToken
    function shares(address account) external view returns (uint256) {
        return _shares[account];
    }

    /// @inheritdoc IRebasingEquityToken
    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    /// @inheritdoc IRebasingEquityToken
    function multiplier() external view returns (uint256) {
        return _multiplier;
    }

    /// @inheritdoc IRebasingEquityToken
    function sharesToAmount(uint256 shareAmount) external view returns (uint256) {
        return _toAmount(shareAmount);
    }

    /// @inheritdoc IRebasingEquityToken
    function sharesToAmountCeil(uint256 shareAmount) external view returns (uint256) {
        return _toAmountCeil(shareAmount);
    }

    /// @inheritdoc IRebasingEquityToken
    function amountToShares(uint256 tokenAmount) external view returns (uint256) {
        return _toShares(tokenAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIMARY PATH: MINT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRebasingEquityToken
    /// @dev ORDERING: backing is reserved in the registry BEFORE shares are
    ///      created. This is not a Checks-Effects-Interactions argument — the
    ///      reasoning is about issuance discipline, not reentrancy: shares must
    ///      never exist without backing already reserved for them, so the
    ///      reservation has to be the step that can fail first. The registry
    ///      enforces `allocated <= custodied`, so if backing is unavailable this
    ///      reverts before any share is issued.
    ///
    ///      Safe to order this way because the registry is a trusted contract
    ///      with no callback path — see the SECURITY MODEL note on the contract.
    function mint(address to, uint256 shareAmount) external onlyRole(PRIMARY_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (shareAmount == 0) revert ZeroAmount();

        // Reserve underlying backing first. Reverts if oversubscribed.
        registry.allocateShares(shareAmount);

        _shares[to] += shareAmount;
        _totalShares += shareAmount;

        uint256 tokenAmount = _toAmount(shareAmount);

        emit Transfer(address(0), to, tokenAmount);
        emit SharesMinted(to, shareAmount, _multiplier, tokenAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          PRIMARY PATH: REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRebasingEquityToken
    /// @dev Shares are destroyed before backing is released. If the release were
    ///      to revert unexpectedly, the whole transaction — including the share
    ///      burn — reverts with it, so the two can never diverge. Atomicity is
    ///      what makes the ordering safe here, not the ordering itself.
    function redeem(uint256 shareAmount) external {
        if (shareAmount == 0) revert ZeroAmount();

        uint256 held = _shares[msg.sender];
        if (shareAmount > held) revert InsufficientShares(shareAmount, held);

        // Captured before the burn so the event reports the value redeemed.
        uint256 tokenAmount = _toAmount(shareAmount);

        _shares[msg.sender] = held - shareAmount;
        _totalShares -= shareAmount;

        registry.releaseShares(shareAmount);

        emit Transfer(msg.sender, address(0), tokenAmount);
        emit SharesRedeemed(msg.sender, shareAmount, _multiplier, tokenAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            CORPORATE ACTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRebasingEquityToken
    /// @dev UP-ONLY POLICY. `newMultiplier` must be strictly greater than the
    ///      current value. Rationale: dividends and forward splits only ever
    ///      increase what a share is worth, and a monotonic multiplier is a far
    ///      stronger thing to reason about — it removes an entire class of
    ///      failure where a downward rebase lands between a quote and its
    ///      settlement and silently reduces what a client receives. Reverse
    ///      splits and negative corporate actions are intentionally out of scope
    ///      for this mock.
    ///
    ///      Deliberately NO per-action cap (e.g. 2x). A legitimate forward split
    ///      can exceed 2x, so a cap would reject valid corporate actions while
    ///      adding no security — the authority that could set 3x could equally
    ///      set 2x twice. The real control is who holds CORPORATE_ACTION_ROLE.
    ///
    ///      THE CRITICAL PROPERTY: this function touches `_multiplier` and
    ///      nothing else. `_shares` and `_totalShares` are not read for writing,
    ///      not modified, and not iterated. Share ownership is untouched.
    function applyCorporateAction(uint256 newMultiplier) external onlyRole(CORPORATE_ACTION_ROLE) {
        if (newMultiplier == 0) revert InvalidMultiplier();

        uint256 oldMultiplier = _multiplier;
        if (newMultiplier <= oldMultiplier) revert MultiplierNotIncreasing(oldMultiplier, newMultiplier);

        _multiplier = newMultiplier;

        emit CorporateActionApplied(oldMultiplier, newMultiplier, _totalShares);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-20 TRANSFERS (TOKEN AMOUNTS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    /// @dev Takes a TOKEN amount. The amount is resolved to shares ONCE and that
    ///      single quantity is both debited and credited, so shares are conserved
    ///      exactly.
    ///
    ///      NOT AN EXACT-AMOUNT PRIMITIVE. Resolution floors, so the value moved
    ///      is bounded by:
    ///
    ///          amount - (multiplier / 1e18)  <  moved  <=  amount
    ///
    ///      i.e. the shortfall is strictly less than the token value of one share,
    ///      and is zero whenever the multiplier divides `amount` cleanly.
    ///
    ///      Flooring is deliberate: it is the only direction that can never debit
    ///      the sender MORE than they asked to send. Rounding up would over-
    ///      extract from the payer and would break DEX routers that approve
    ///      exactly `amountIn`, since the debit could then require `amountIn + 1`.
    ///
    ///      Callers that need an exact quantity must use {transferShares}. Callers
    ///      integrating with an AMM must measure balance deltas — see the AMM /
    ///      DEX INTEGRATION RULE on this contract, which explains why no rounding
    ///      policy here can make a balance delta predictable.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transferShares(msg.sender, to, _resolveShares(amount));
        return true;
    }

    /// @inheritdoc IERC20
    /// @dev Takes a TOKEN amount, and spends `amount` of allowance — the amount
    ///      requested, not the marginally smaller amount that rounding may
    ///      actually move. Charging the full request is the conservative
    ///      direction: it can never let a spender move more than approved.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transferShares(from, to, _resolveShares(amount));
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        SHARE-EXACT TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRebasingEquityToken
    function transferShares(address to, uint256 shareAmount) external returns (bool) {
        if (shareAmount == 0) revert ZeroAmount();
        _transferShares(msg.sender, to, shareAmount);
        return true;
    }

    /// @inheritdoc IRebasingEquityToken
    /// @dev The allowance debit is the token value of `shareAmount` ROUNDED UP.
    ///      Rounding up here is the mirror of charging the full request in
    ///      {transferFrom}: both ensure the allowance is never under-charged for
    ///      the value actually moved.
    function transferSharesFrom(address from, address to, uint256 shareAmount) external returns (bool) {
        if (shareAmount == 0) revert ZeroAmount();
        _spendAllowance(from, msg.sender, _toAmountCeil(shareAmount));
        _transferShares(from, to, shareAmount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                ALLOWANCES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC20
    /// @dev TOKEN-DENOMINATED, and this is a deliberate trade-off worth stating.
    ///      Because the allowance is fixed in token terms while the multiplier
    ///      rises, an allowance buys progressively FEWER shares over time: 100
    ///      tokens approved at multiplier 1e18 is 100 shares, but only 50 shares
    ///      after the multiplier doubles.
    ///
    ///      Chosen anyway, because the alternative is worse. A share-denominated
    ///      allowance would silently grow in token terms after every corporate
    ///      action, so an approval a user reasoned about in tokens would let a
    ///      spender take more value than they had in mind. It would also break
    ///      every integrator that reads `allowance` and compares it to a token
    ///      amount, which is what wallets, routers, and DEXes all do. Decaying
    ///      purchasing power is visible and fails safe; silently growing
    ///      purchasing power is invisible and fails open.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc IERC20
    /// @dev Takes a TOKEN amount. Conventional set-to-value semantics.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();

        _allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc IRebasingEquityToken
    /// @dev ONE ALLOWANCE MAPPING, TWO DENOMINATIONS OF ACCESS TO IT. This writes
    ///      the same `_allowances` slot {approve} writes, converted at the current
    ///      multiplier and rounded UP with {_toAmountCeil}.
    ///
    ///      Rounding up is what makes the grant honest. {transferSharesFrom} debits
    ///      `_toAmountCeil(shareAmount)`, so approving the floored value would be
    ///      up to one wei short and the very transfer this approval exists to
    ///      permit could revert. Ceil on both sides means a grant of `s` shares is
    ///      immediately spendable as `s` shares.
    ///
    ///      Deliberately NOT a second mapping. A separate share-denominated
    ///      allowance would have to be reconciled with the token-denominated one on
    ///      every spend, and any disagreement between them is an authorisation bug
    ///      by definition — one of the two would be granting access the owner did
    ///      not intend. Deriving both views from a single stored quantity makes that
    ///      class of bug unrepresentable.
    ///
    ///      Consequence carried over from {allowance}: what this grants is a fixed
    ///      TOKEN allowance, so the SHARE permission it represents never grows and
    ///      decays as the multiplier rises. See {allowanceShares}.
    function approveShares(address spender, uint256 shareAmount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();

        uint256 amount = _toAmountCeil(shareAmount);
        _allowances[msg.sender][spender] = amount;

        // Reports the TOKEN amount stored, not the share amount requested, because
        // that is what the allowance now is and what every ERC-20 integrator will
        // read back. Emitting the share figure here would put a quantity in the log
        // that no `allowance` call ever returns.
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc IRebasingEquityToken
    /// @dev The floor half of the ceil/floor pair. `_toShares` of a stored
    ///      allowance `A` is `floor(A * 1e18 / m)`, which is decreasing in `m`:
    ///      spending power in share terms never increases across a corporate
    ///      action. It can stay EQUAL across a small multiplier increase, because
    ///      the ceil applied at approval time leaves up to one wei of headroom —
    ///      it does not strictly decrease on every rebase.
    function allowanceShares(address owner, address spender) external view returns (uint256) {
        return _toShares(_allowances[owner][spender]);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @dev THE ONLY PLACE SHARES MOVE BETWEEN ACCOUNTS. Debits and credits the
    ///      identical `shareAmount`, so the sum of all shares is invariant under
    ///      any transfer. Both token-denominated and share-exact entry points
    ///      funnel through here, so there is exactly one implementation of the
    ///      conservation rule to audit.
    function _transferShares(address from, address to, uint256 shareAmount) private {
        if (to == address(0)) revert ZeroAddress();

        uint256 fromShares = _shares[from];
        if (shareAmount > fromShares) revert InsufficientShares(shareAmount, fromShares);

        _shares[from] = fromShares - shareAmount;
        _shares[to] += shareAmount;

        // The event reports the token value of the shares ACTUALLY moved, not the
        // amount originally requested. Reporting the request would overstate the
        // transfer whenever rounding applied, and leave logs disagreeing with
        // balances. Note the sender's and recipient's displayed balances may each
        // shift by amounts differing by up to 1 wei, because each is floored
        // independently -- the shares moved are exact, the display is not.
        emit Transfer(from, to, _toAmount(shareAmount));
    }

    /// @dev Converts a token amount to shares for transfer, rejecting a result of
    ///      zero. A zero-share transfer would return true and emit a Transfer
    ///      while moving nothing, which is indistinguishable from a real transfer
    ///      to any integrator watching events or return values. Failing loudly is
    ///      strictly safer than a silent no-op.
    function _resolveShares(uint256 amount) private view returns (uint256 shareAmount) {
        if (amount == 0) revert ZeroAmount();

        shareAmount = _toShares(amount);
        if (shareAmount == 0) revert TransferRoundsToZeroShares(amount, _multiplier);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: ALLOWANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is
    ///      not decremented — the conventional ERC-20 optimisation, kept so
    ///      integrators that rely on it behave normally here.
    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;

        if (amount > current) revert InsufficientAllowance(amount, current);

        uint256 remaining = current - amount;
        _allowances[owner][spender] = remaining;

        emit Approval(owner, spender, remaining);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: CONVERSIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Token amount -> shares, rounded DOWN.
    ///      `Math.mulDiv` computes the product at full 512-bit width, so an
    ///      intermediate `amount * 1e18` that would overflow uint256 does not,
    ///      and only a genuinely out-of-range RESULT reverts.
    function _toShares(uint256 tokenAmount) internal view returns (uint256) {
        return Math.mulDiv(tokenAmount, MULTIPLIER_SCALE, _multiplier);
    }

    /// @dev Shares -> token amount, rounded DOWN. Full-precision for the same
    ///      reason as {_toShares}.
    function _toAmount(uint256 shareAmount) internal view returns (uint256) {
        return Math.mulDiv(shareAmount, _multiplier, MULTIPLIER_SCALE);
    }

    /// @dev Shares -> token amount, rounded UP. Used only for allowance debits,
    ///      where under-charging would let a spender move more value than the
    ///      owner approved.
    function _toAmountCeil(uint256 shareAmount) internal view returns (uint256) {
        return Math.mulDiv(shareAmount, _multiplier, MULTIPLIER_SCALE, Math.Rounding.Ceil);
    }
}
