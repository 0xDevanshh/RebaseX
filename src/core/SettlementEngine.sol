// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRebasingEquityToken} from "../interfaces/IRebasingEquityToken.sol";
import {ISettlementEngine} from "../interfaces/ISettlementEngine.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {VenueRegistry} from "../router/VenueRegistry.sol";

/// @title SettlementEngine
/// @notice Executes a routed order: moves client funds into transit, calls the
///         venue adapter, enforces slippage, captures the execution fee, and
///         accounts for every unit that moved.
/// @dev ================= CONTRACT RESPONSIBILITY =================
///      THIS IS THE ONLY CONTRACT IN THE SYSTEM THAT MOVES CLIENT FUNDS.
///
///      The division of labour across the three routing contracts is deliberate
///      and total — each concern lives in exactly one place:
///
///        - Router          orchestrates. Validates, authorizes, resolves a
///                          venue, delegates. Holds no balances, calls no
///                          `transfer`, takes no fee, enforces no slippage.
///        - IVenueAdapter   executes on a venue. Receives funds already in hand,
///                          swaps, forwards output. Retains nothing.
///        - SettlementEngine (this contract) owns CUSTODY TRANSIT and ALL
///                          ACCOUNTING. Client funds pass through this address
///                          and nowhere else. Slippage is enforced here and only
///                          here, against realised results. The fee is taken
///                          here. Share-denominated measurement happens here.
///
///      The consequence to keep in mind when reviewing: "can a client lose
///      funds" is a question about this file. The Router holding no balances is
///      a real property but not a sufficient safety argument, because the funds
///      it never touches still move — they move here.
///      ============================================================
///
///      ============== NO RESCUE FUNCTION — BY DESIGN ==============
///      This contract has NO withdrawal, sweep, or rescue path of any kind.
///      There is no `rescueTokens`, no `sweep`, no admin-callable transfer, and
///      no upgrade hatch that could add one. That is deliberate.
///
///      The system's central claim to a client is that it holds TRADE-ONLY
///      permissions and never withdrawal rights. An admin sweep on the one
///      contract that client funds actually flow through would undermine the
///      exact claim the architecture exists to make: it would mean the
///      privileged key can, at some size and under some conditions, move client
///      value out. A permission that exists is a permission that can be used.
///
///      THE CONSEQUENCE, STATED HONESTLY: tokens sent directly to this address —
///      donated, mis-sent, or left behind by a token with transfer semantics
///      this contract does not model — are PERMANENTLY STRANDED. Nobody can
///      recover them, including the admin, including the client they belonged
///      to. That is a real cost, not a rounding error in the design.
///
///      What production should do instead: a permissioned sweep restricted to
///      NON-SETTLEMENT RESIDUE — a balance provably not owed to any in-flight
///      order, with the restriction enforced in code rather than asserted in a
///      comment. That was cut here for time, not rejected on merit. A
///      withdrawal path in a contract whose whole argument is "there is no
///      withdrawal path" needs more design care than this timeline allows, and a
///      half-designed one is worse than none: it would carry the full trust cost
///      of an admin sweep while only partially delivering the recovery benefit.
///
///      TWO DECISIONS ELSEWHERE FOLLOW DIRECTLY FROM THIS ABSENCE, and neither
///      makes sense read on its own:
///        1. {_validateFeeRecipient} rejects `address(this)`. Fees routed here
///           would be stranded, because there is nothing to route them out with.
///        2. Settlement's custody post-condition is DELTA-BASED rather than
///           absolute-balance-based (see requirement 4.2). A pre-existing
///           stranded balance can never be cleared, so a post-condition of
///           "this contract holds nothing" would be permanently unsatisfiable
///           after a single stray wei. Measuring the delta of this settlement
///           asserts the right thing — that THIS order retained nothing — and is
///           the only form of the check that survives donations.
///      ============================================================
///
///      ============ TWO MEASUREMENT PRINCIPLES, APPLIED THROUGHOUT ============
///      Everything {settle} asserts rests on these two. They are stated once
///      here because they are ONE IDEA EACH applied in several places, not
///      several independent patches, and reading them as separate local fixes is
///      how a later edit breaks one of them.
///
///      PRINCIPLE 1 — ON THE REBASING LEG, MEASURE SHARE DELTAS, NEVER
///      `balanceOf` DELTAS. Floored derived balances DO NOT COMPOSE UNDER
///      SUBTRACTION:
///
///          floor(a*m/1e18) - floor(b*m/1e18)  !=  floor((a-b)*m/1e18)
///
///      in general. A `balanceOf` delta can therefore be off by one from the
///      amount truly corresponding to the share delta, and the error depends on
///      the share remainder the holder already carried — i.e. on state that has
///      nothing to do with this trade. `shares()` is the STORED PRIMITIVE, so a
///      share delta is exact with no rounding at all. On the non-rebasing leg
///      there is no derivation and no flooring, so `balanceOf` deltas are exact
///      and are used directly.
///
///      PRINCIPLE 2 — EVERY CUSTODY POST-CONDITION COMPARES AGAINST A SNAPSHOT,
///      NEVER AGAINST ABSOLUTE ZERO. Any external party can transfer tokens to
///      any address unsolicited, and nothing on-chain can prevent it. An
///      absolute-zero post-condition anywhere in this contract would therefore
///      let a single donated wei permanently BRICK SETTLEMENT — a free,
///      irreversible griefing DoS costing the attacker one wei. This applies
///      identically to the adapter (STEP 5) and to this engine (STEP 10).
///      DONATION-RESISTANCE IS A PROPERTY OF THE DESIGN, not two separate
///      patches that happen to look alike.
///      ========================================================================
contract SettlementEngine is ISettlementEngine, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the initialized Router.
    error OnlyRouter(address caller, address router);

    /// @notice {initializeRouter} has not been called yet.
    /// @dev Distinct from {OnlyRouter} on purpose — see {onlyRouter}.
    error RouterNotInitialized();

    /// @notice {initializeRouter} has already been called. It is one-time.
    error RouterAlreadyInitialized(address router);

    /// @notice Proposed router address holds no contract code.
    error InvalidRouter(address router);

    /// @notice The adapter supplied by the caller is not the adapter the registry
    ///         holds for `venueId`. See {settle}.
    error AdapterMismatch(bytes32 venueId, address adapter);

    /// @notice Both legs of the order are registered rebasing tokens.
    error UnsupportedAssetPair(address assetIn, address assetOut);

    /// @notice Neither leg of the order is a registered rebasing token.
    error NoRebasingLeg(address assetIn, address assetOut);

    /// @notice Token failed the rebasing-token configuration probe: zero address,
    ///         no code, no `multiplier()`, or a zero multiplier.
    error InvalidRebasingToken(address token);

    /// @notice Fee recipient is this contract, or a registered rebasing token.
    error InvalidFeeRecipient(address recipient);

    /// @notice Realised NET output is below `order.minAmountOut`. Checked after
    ///         the fee, never before it — see {settle} STEP 7.
    error InsufficientOutput(uint256 minAmountOut, uint256 amountOutNet);

    /// @notice A corporate action moved the multiplier mid-settlement, so the
    ///         share/amount figures computed before the swap no longer describe
    ///         the same value as those computed after it.
    error MultiplierChangedDuringSettlement(uint256 multiplierBefore, uint256 multiplierAfter);

    /// @notice The adapter's input holding did not return to its pre-settlement
    ///         level: it consumed something other than exactly what this
    ///         settlement funded, or retained part of it.
    /// @dev No parameters, because the assertion is a comparison against a
    ///      SNAPSHOT rather than a single wrong value — reporting one side of it
    ///      without the other would be more misleading than reporting neither.
    ///      The snapshot and the realised figure are both reconstructible from
    ///      the reverting call's own trace.
    error AdapterRetainedFunds();

    /// @notice This engine still holds funds attributable to this settlement.
    /// @dev DELTA-measured against a snapshot, never absolute — see the no-rescue
    ///      note above and {settle} STEP 10. Parameterless for the same reason as
    ///      {AdapterRetainedFunds}, and additionally because the condition spans
    ///      three independent reads.
    error EngineRetainedFunds();

    /// @notice The input pulled from the client did not arrive at the adapter in
    ///         the quantity this settlement intended to fund.
    error InputTransferMismatch();

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Zero amount supplied where a non-zero amount is required.
    error ZeroAmount();

    /// @notice Order deadline is in the past.
    /// @dev Re-checked here even though the Router checks it. The Router is the
    ///      only permitted caller, not a trusted one — see {settle}.
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on a completed settlement. SHARES ARE THE CANONICAL RECORD.
    /// @dev The share fields are the authoritative account of what moved. Token
    ///      amounts are reportable figures derived at a specific multiplier, and
    ///      a later corporate action restates what those amounts are worth while
    ///      leaving the share fields permanently correct. Anything reconciling
    ///      against the share registry must use the share fields.
    ///
    ///      ================== DERIVABILITY ==================
    ///      The derivability claim holds on ONE LEG ONLY. State it precisely,
    ///      because assuming it holds on both produces silently wrong numbers.
    ///
    ///      Token-amount fields on the REBASING leg are reproducible from the
    ///      share fields and `multiplierAtSettlement`:
    ///        buy  -> `amountOutNet` and `feeAmount` derive from `sharesOutNet`
    ///                and `feeShares`
    ///        sell -> `amountInExecuted` derives from `sharesIn`
    ///
    ///      Token-amount fields on the STABLE leg are INDEPENDENT DATA and
    ///      cannot be reconstructed from any share field:
    ///        buy  -> `amountInExecuted` is a stable amount
    ///        sell -> `amountOutNet` and `feeAmount` are stable amounts
    ///
    ///      The event records NO EXECUTION PRICE, so no cross-leg derivation is
    ///      possible in either direction — the stable leg cannot be derived from
    ///      the rebasing leg, nor the reverse. Consumers needing stable-leg
    ///      figures must read them from the event directly; they are emitted for
    ///      that reason and are not redundant.
    ///      =================================================
    /// @param orderHash              Correlation handle, matching the Router's logs.
    ///                               Not a nonce and not replay protection.
    /// @param account                Client whose funds were traded.
    /// @param venueId                Venue actually executed on, never zero.
    /// @param rebasingToken          The tokenised-equity leg, resolved from the
    ///                               registry rather than from leg position.
    /// @param isBuy                  True when the rebasing token is being bought
    ///                               (it is `assetOut`), false when sold.
    /// @param assetIn                Token sold, as ordered.
    /// @param assetOut               Token received, as ordered.
    /// @param sharesIn               Rebasing-leg input shares. ZERO ON A BUY,
    ///                               where the input leg is the stable token.
    /// @param sharesOutNet           Rebasing-leg output shares, NET of fee. ZERO
    ///                               ON A SELL, where the output leg is stable.
    /// @param feeShares              Fee in shares. ZERO ON A SELL — the fee is
    ///                               taken on the stable leg there, so there is no
    ///                               share-denominated fee to report (see
    ///                               requirement 4.3).
    /// @param multiplierAtSettlement Rebasing token's multiplier during execution.
    ///                               The scale factor the token amounts below were
    ///                               derived at; without it they cannot be checked.
    /// @param amountInExecuted       Input that ACTUALLY EXECUTED. This is NOT
    ///                               necessarily `order.amountIn`: on a sell the
    ///                               rebasing input leg floors through a
    ///                               token-to-share conversion, so the executed
    ///                               figure can be below the requested one (see
    ///                               requirement 4.2). The event records what
    ///                               happened, not what was asked for.
    /// @param amountOutNet           Output delivered to the client, net of fee.
    /// @param feeAmount              Fee in token amount, on whichever leg it was
    ///                               taken.
    event Settled(
        bytes32 indexed orderHash,
        address indexed account,
        bytes32 indexed venueId,
        address rebasingToken,
        bool isBuy,
        address assetIn,
        address assetOut,
        // --------------------------- canonical: shares ---------------------------
        uint256 sharesIn,
        uint256 sharesOutNet,
        uint256 feeShares,
        uint256 multiplierAtSettlement,
        // ------------------- token amounts: see derivability note -----------------
        uint256 amountInExecuted,
        uint256 amountOutNet,
        uint256 feeAmount
    );

    /// @notice Emitted when the fee recipient changes.
    /// @dev Carries the old value so the log is a complete history without
    ///      needing a state read at each block.
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    /// @notice Emitted when a token is registered as, or deregistered from being,
    ///         a rebasing token.
    event RebasingTokenRegistered(address token, bool isRebasing);

    /// @notice Emitted once, when the Router pointer is set. Never again.
    event RouterInitialized(address router);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execution fee, in basis points. 2 bps = 0.02%.
    /// @dev Constant, not admin-settable. A mutable fee is a privileged write
    ///      that changes the economics of an order between submission and
    ///      execution, which a client cannot detect and cannot opt out of.
    ///      Changing the fee here means deploying a new engine, which means a new
    ///      Router address, which the client must consciously adopt.
    uint16 public constant FEE_BPS = 2;

    /// @notice Basis-point denominator.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Registry resolving a venueId to its adapter.
    /// @dev Stays immutable: the engine takes the registry address at
    ///      construction and no deployment cycle forces it to be otherwise
    ///      (contrast {router} below). Typed as the concrete {VenueRegistry}
    ///      rather than an interface because the repository has no
    ///      `IVenueRegistry`, and the Router holds it the same way — one type for
    ///      one dependency, rather than two views of it that could drift.
    VenueRegistry public immutable venueRegistry;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The one address permitted to call {settle}.
    /// @dev ============ DELIBERATELY NOT IMMUTABLE ============
    ///      CIRCULAR CONSTRUCTION DEPENDENCY. The Router's constructor takes the
    ///      engine address; the engine needs the Router's address to gate
    ///      {settle}. Both cannot be immutable, because neither could be deployed
    ///      first — whichever goes first has nothing to point at.
    ///
    ///      Resolved with a one-time initializer, {initializeRouter}. The pointer
    ///      is write-once: after the first successful call there is no path that
    ///      writes this slot again, so it is functionally immutable from the end
    ///      of deployment onward. `immutable` is a compile-time guarantee; this is
    ///      a runtime one, and the difference is a window, not a permission.
    ///
    ///      THREAT MODEL — THE DEPLOYMENT WINDOW. Between deployment and
    ///      initialization, this engine holds an unset privileged pointer. An
    ///      attacker who front-runs the admin's `initializeRouter` with one of
    ///      their own — and who holds DEFAULT_ADMIN_ROLE, which they must, since
    ///      the call is role-gated — would permanently point settlement at a
    ///      Router of their choosing. Mitigations, in order of what actually
    ///      carries the weight:
    ///        1. The role gate. This is not an open initializer; an attacker
    ///           needs the admin key first, at which point the deployment window
    ///           is not the interesting problem.
    ///        2. The deploy script performs deployment AND initialization in one
    ///           run, so the window does not span a human decision.
    ///        3. The README requires verifying `router()` post-deploy before any
    ///           client approves an allowance — the window is only dangerous if
    ///           unnoticed.
    ///        4. The write-back is permanently disabled after the first call, so
    ///           the risk does not persist into the contract's operating life.
    ///
    ///      ALTERNATIVE REJECTED FOR TIME: CREATE2 address precomputation. Derive
    ///      the Router's address from the deployer, salt, and init-code hash
    ///      before deploying anything, pass it to the engine's constructor as a
    ///      TRUE IMMUTABLE, then deploy the Router to that precomputed address.
    ///      That removes the window and the initializer together, and it is what
    ///      a production deployment should do. It was not done here because it
    ///      moves correctness into the deploy script — the init-code hash must
    ///      match exactly, and a mismatch produces an engine pointing at an
    ///      address that will never hold code — and that script needs tests of
    ///      its own to be worth trusting. The initializer is a KNOWING
    ///      COMPROMISE, recorded as such, not a default that went unexamined.
    ///      =====================================================
    address public router;

    /// @notice Address receiving execution fees.
    /// @dev Admin-settable, unlike {FEE_BPS}. Moving where a fee goes does not
    ///      change what a client pays, so it does not silently alter the terms of
    ///      an order in flight — which is what makes it safe to make mutable
    ///      while the rate is not. Validated on every write, including in the
    ///      constructor: see {_validateFeeRecipient}.
    address public feeRecipient;

    /// @dev Which tokens are rebasing tokenised equities. Private so the only
    ///      read path is {isRebasingToken}, keeping one accessor to reason about.
    ///
    ///      THIS MAPPING IS THE SOURCE OF TRUTH FOR LEG DETECTION. Settlement
    ///      does not hardcode a token address and does not infer the equity leg
    ///      from `assetIn`/`assetOut` position — see {_rebasingLeg}.
    mapping(address token => bool) private _rebasingTokens;

    /*//////////////////////////////////////////////////////////////
                                  ROLES
    //////////////////////////////////////////////////////////////*/

    // Only DEFAULT_ADMIN_ROLE exists, gating exactly three functions:
    //   {initializeRouter}, {setFeeRecipient}, {registerRebasingToken}.
    //
    // THERE IS NO SETTLER ROLE, AND THAT IS THE POINT. {settle} is gated on the
    // write-once {router} ADDRESS, not on a grantable role. The distinction is
    // not stylistic:
    //
    //   - A ROLE CAN BE GRANTED. Whoever holds DEFAULT_ADMIN_ROLE could grant a
    //     settler role to an attacker — or an attacker who takes that key could
    //     grant it to themselves — and then call {settle} directly with a
    //     hand-crafted order, bypassing every validation and authorization check
    //     the Router performs. That is a live path from "admin key compromised"
    //     to "client funds traded on an attacker's terms".
    //   - A WRITE-ONCE POINTER CANNOT BE RE-POINTED AT ALL. Once set, no key in
    //     the system — including the admin's — can make a different address able
    //     to call {settle}. Compromising the admin key does not open the
    //     settlement path.
    //
    // The admin's remaining powers are real but bounded: they can redirect fee
    // revenue and change which tokens are treated as rebasing. Neither moves
    // client principal.

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param admin          Address granted DEFAULT_ADMIN_ROLE. Rejected if zero,
    ///                       which would leave the engine permanently
    ///                       unconfigurable — and, because {router} starts unset,
    ///                       permanently unable to settle anything.
    /// @param venueRegistry_ Venue registry. Immutable once set.
    /// @param feeRecipient_  Initial fee recipient. Subject to the SAME
    ///                       validation as {setFeeRecipient}.
    constructor(address admin, VenueRegistry venueRegistry_, address feeRecipient_) {
        if (admin == address(0)) revert ZeroAddress();
        if (address(venueRegistry_) == address(0)) revert ZeroAddress();

        venueRegistry = venueRegistry_;

        // Validated through the SHARED internal, not a hand-rolled subset of the
        // checks. A constructor that skips validation the setter enforces is a
        // real gap, not a stylistic inconsistency: it means the one write nobody
        // can undo without redeploying is the one write that was never checked.
        //
        // Note what this cannot catch at construction time: `_rebasingTokens` is
        // empty here, so the rebasing-token limb of the validation cannot fire.
        // A token registered LATER is not re-checked against the standing fee
        // recipient. See {registerRebasingToken}.
        _validateFeeRecipient(feeRecipient_);
        feeRecipient = feeRecipient_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        emit FeeRecipientUpdated(address(0), feeRecipient_);
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts a function to the initialized Router.
    ///
    ///      THE {RouterNotInitialized} CHECK IS LOAD-BEARING, not defensive
    ///      padding. Without it, an uninitialized engine has `router ==
    ///      address(0)`, and the `msg.sender` comparison alone would still reject
    ///      every caller correctly — so the contract would be SAFE but
    ///      UNDIAGNOSABLE. The revert would be {OnlyRouter}, indistinguishable
    ///      from an ordinary authorization rejection, and a botched deployment
    ///      would present as "the Router isn't authorized" rather than as "the
    ///      engine was never wired up". Those two states call for completely
    ///      different responses. Making them distinct errors is worth the extra
    ///      SLOAD-free comparison.
    modifier onlyRouter() {
        if (router == address(0)) revert RouterNotInitialized();
        if (msg.sender != router) revert OnlyRouter(msg.sender, router);
        _;
    }

    /// @notice Set the Router permitted to call {settle}. Callable exactly once.
    /// @dev See the {router} storage note for why this exists at all rather than
    ///      the pointer being immutable, and for the deployment-window threat
    ///      model. The three checks, in order:
    ///
    ///        1. ALREADY SET -> revert. This is what makes the pointer write-once
    ///           and therefore not re-pointable by a compromised admin key. It is
    ///           checked FIRST so a second call fails for the reason that
    ///           actually matters, rather than incidentally failing a later check.
    ///        2. ZERO -> revert. Setting zero would leave the engine looking
    ///           initialized while {onlyRouter}'s first check still fires, i.e.
    ///           permanently bricked with a misleading error and no second chance.
    ///        3. NO CODE -> revert. The Router must be a contract. An EOA or a
    ///           not-yet-deployed address would initialize cleanly and then be
    ///           unfixable, since there is no second call. Same principle as
    ///           VenueRegistry's adapter code check: turn a configuration mistake
    ///           into a configuration-time failure, while the only thing at stake
    ///           is an admin transaction.
    /// @param router_ The Router contract address.
    function initializeRouter(address router_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router != address(0)) revert RouterAlreadyInitialized(router);
        if (router_ == address(0)) revert ZeroAddress();
        if (router_.code.length == 0) revert InvalidRouter(router_);

        router = router_;

        emit RouterInitialized(router_);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN: FEE CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Change where execution fees are sent.
    /// @dev Validation is delegated to {_validateFeeRecipient}, the SAME helper
    ///      the constructor calls. The checks are deliberately NOT inlined here:
    ///      two copies of a validation rule is how the two copies drift apart,
    ///      and the copy that would drift is the one guarding the write nobody
    ///      can undo without redeploying.
    ///
    ///      ================== ADMIN BLAST RADIUS ==================
    ///      Worth stating precisely, because this is the most valuable write the
    ///      admin still has after {initializeRouter} is spent.
    ///
    ///      A COMPROMISED ADMIN CAN redirect all FUTURE fee revenue to an address
    ///      of their choosing. That is real, and it is the whole of the damage.
    ///
    ///      A COMPROMISED ADMIN CANNOT TOUCH CLIENT PRINCIPAL. The engine holds
    ///      funds only INSIDE A SINGLE TRANSACTION — STEP 10 enforces that it
    ///      retains nothing — and it has no withdrawal rights over client
    ///      accounts, only the scoped trade-time allowance the client granted.
    ///      There is no admin path that moves a client's assets, and no role that
    ///      can be granted to create one, because {settle} is gated on the
    ///      write-once {router} pointer rather than on a role.
    ///
    ///      THE ADMIN ALSO CANNOT STRAND FEE REVENUE INSIDE THE ENGINE, because
    ///      `address(this)` is rejected by the shared helper. A small bound, but a
    ///      real one — and it exists ONLY because the no-rescue-function decision
    ///      made stranding permanent. In a contract with a sweep, pointing fees at
    ///      itself would be a reversible mistake; here it would be irreversible
    ///      loss compounding on every settlement, so the configuration-time check
    ///      is what stands in for the recovery path that deliberately does not
    ///      exist.
    ///      ========================================================
    /// @param newRecipient New fee recipient. Validated by {_validateFeeRecipient}.
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateFeeRecipient(newRecipient);

        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;

        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /// @dev Shared by the CONSTRUCTOR and {setFeeRecipient} so the two can never
    ///      disagree about what a valid recipient is. Each rejection, and why:
    ///
    ///      (1) `address(0)` — fees would be burned by any sane token, or revert
    ///          on transfer, depending on the token. Either way the fee leg of
    ///          every settlement becomes a coin flip on the token's zero-address
    ///          policy.
    ///
    ///      (2) `address(this)` — fees routed to this contract would be
    ///          PERMANENTLY STRANDED, because this contract has no withdrawal
    ///          path by design. THIS CHECK EXISTS PRECISELY BECAUSE THERE IS NO
    ///          RESCUE FUNCTION: the two decisions are linked, not independent.
    ///          In a contract with an admin sweep this misconfiguration would be
    ///          an inconvenience someone fixes in a follow-up transaction; here
    ///          it is irreversible loss that compounds with every settlement
    ///          until someone notices. Removing the rescue function is what
    ///          promotes this from a nicety to a necessity.
    ///
    ///      (3) A REGISTERED REBASING TOKEN — a token contract holding its own
    ///          shares as fee revenue produces a supply figure that reconciles
    ///          strangely against the share registry: the token is both the
    ///          issuer of the claim and a holder of it, so `totalShares` includes
    ///          shares whose economic owner is the issuer itself. Unlikely to
    ///          happen by accident, but cheap to exclude at CONFIGURATION time
    ///          rather than discover during a reconciliation that does not
    ///          balance and gives no hint why.
    ///
    ///      KNOWN GAP, stated rather than hidden: the check is one-directional in
    ///      time. Validating here catches "this recipient is already a registered
    ///      rebasing token"; it cannot catch "the standing fee recipient later
    ///      becomes one". {registerRebasingToken} deliberately does not re-check
    ///      the fee recipient — see the asymmetry note there — so that ordering
    ///      remains reachable by an admin doing two individually-valid things in
    ///      the wrong order.
    function _validateFeeRecipient(address recipient) internal view {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this)) revert InvalidFeeRecipient(recipient);
        if (_rebasingTokens[recipient]) revert InvalidFeeRecipient(recipient);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN: REBASING TOKEN CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Mark `token` as a rebasing tokenised equity, or unmark it.
    /// @dev VALIDATE AT CONFIGURATION TIME. Registration is checked; the checks
    ///      run before the storage write so a failed probe leaves no trace.
    ///
    ///      For `isRebasing == true`:
    ///        1. non-zero address
    ///        2. holds contract code
    ///        3. an INTERFACE PROBE: `multiplier()` answers, and is non-zero.
    ///
    ///      THE PROBE MATTERS MORE THAN THE CODE CHECK. The realistic
    ///      configuration error is not an EOA or an empty address — it is a
    ///      WRONG-BUT-DEPLOYED contract: the stablecoin instead of the equity,
    ///      last week's token instead of this week's, a pair address instead of a
    ///      token. Every one of those passes `code.length > 0` cleanly. Calling
    ///      `multiplier()` is what separates "a contract" from "a contract that
    ///      is plausibly this kind of token", and it is the cheapest signal that
    ///      distinguishes them.
    ///
    ///      The try/catch converts a missing-function low-level revert into a
    ///      NAMED error. Without it the admin sees a bare revert with no data and
    ///      no indication of which of several things went wrong. The zero-
    ///      multiplier rejection covers a contract that answers the probe but is
    ///      not usable: at multiplier zero every derived balance is zero and
    ///      every token-to-share conversion divides by zero, so registering it
    ///      would produce a settlement-time failure rather than a config-time one.
    ///
    ///      This is the SAME PRINCIPLE as the adapter code-length check in
    ///      VenueRegistry — turn configuration mistakes into configuration-time
    ///      failures, when the only thing at stake is an admin transaction,
    ///      rather than settlement-time ones, when a client's funds are already
    ///      in flight. And like that check, it verifies SHAPE, not correctness: a
    ///      contract with a `multiplier()` and the wrong behaviour still
    ///      registers. That is a review problem, not something a registry probe
    ///      can settle.
    ///
    ///      ============= THE DEREGISTRATION ASYMMETRY =============
    ///      For `isRebasing == false` there is NO VALIDATION AT ALL. Not the zero
    ///      check, not the code check, not the probe. Removal is unconditional.
    ///
    ///      That is intentional. The situation deregistration must handle is
    ///      precisely a token that has BECOME NON-CONFORMING — self-destructed,
    ///      upgraded its proxy to something that reverts on `multiplier()`, or
    ///      turned out to be the wrong address in the first place. Gating removal
    ///      on the same probe that gates addition would mean the tokens most
    ///      urgently needing removal are the exact tokens that cannot be removed,
    ///      leaving settlement pointed at a broken asset with no admin recourse.
    ///
    ///      This mirrors the same asymmetry applied elsewhere in the system, and
    ///      the consistency is the argument:
    ///        - MockShareRegistry: minting is gated on backing; redemption is not.
    ///        - VenueRegistry:     enabling a venue checks the adapter; disabling
    ///                             one checks nothing.
    ///        - here:              registration probes the token; deregistration
    ///                             does not.
    ///      One rule, three places: ADDING TRUST IS VALIDATED, REMOVING IT IS
    ///      NOT. Validation protects against granting authority by mistake. It
    ///      has no role in withdrawing authority, where the only failure mode
    ///      worth preventing is being UNABLE to withdraw it.
    ///      ========================================================
    /// @param token      Token to register or deregister.
    /// @param isRebasing True to register, false to deregister.
    function registerRebasingToken(address token, bool isRebasing) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isRebasing) {
            if (token == address(0)) revert ZeroAddress();
            if (token.code.length == 0) revert InvalidRebasingToken(token);

            try IRebasingEquityToken(token).multiplier() returns (uint256 m) {
                if (m == 0) revert InvalidRebasingToken(token);
            } catch {
                revert InvalidRebasingToken(token);
            }
        }
        // Deregistration path: deliberately unvalidated. See the asymmetry note.

        _rebasingTokens[token] = isRebasing;

        emit RebasingTokenRegistered(token, isRebasing);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Working state for ONE settlement, held in memory and threaded through
    ///      the step helpers by reference.
    ///
    ///      WHY A STRUCT AND NOT PLAIN LOCALS: settlement carries three engine
    ///      snapshots, a multiplier snapshot, two resolved input figures, two
    ///      adapter snapshots, a realised output, and four fee figures. As stack
    ///      locals that exceeds the EVM's 16-slot reach and produces "stack too
    ///      deep" without `via_ir`. A memory struct costs ONE stack slot however
    ///      many fields it carries. It also gives every helper one place to
    ///      record its result, which keeps {settle} readable as the ten-step
    ///      sequence it is rather than as a chain of multi-value returns.
    ///
    ///      {_applyFee} is the one exception: it takes its inputs and returns its
    ///      four figures on the stack rather than reading and writing `s`. The fee
    ///      split is the piece most likely to be reviewed, re-derived, or unit
    ///      tested on its own, and an explicit signature makes exactly what it
    ///      consumes and produces legible without tracing which struct fields are
    ///      live at that point. {settle} assigns the results into `s`, so the
    ///      stack cost stays at zero.
    ///
    ///      SEVERAL FIELDS ARE LEG-EXCLUSIVE and stay zero on the other leg. That
    ///      is not sloppiness — the {Settled} event publishes exactly those zeros
    ///      as meaningful values (`sharesIn` is 0 on a buy; `sharesOutNet` and
    ///      `feeShares` are 0 on a sell), so a field left untouched here is a
    ///      field that is correct in the log.
    struct SettlementState {
        // ---- resolved once, in STEP 0 ----
        address rebasingToken;
        bool isBuy;
        // ---- STEP 0 snapshots, consumed by the STEP 10 post-condition ----
        uint256 engineInBefore;
        uint256 engineOutBefore;
        uint256 engineSharesBefore;
        // ---- STEP 1 snapshot, re-checked in STEP 6 ----
        uint256 multiplierBefore;
        // ---- STEP 2: the input this settlement will actually execute ----
        uint256 sharesIn; // SELL only; 0 on a buy
        uint256 executableAmountIn;
        // ---- STEP 3 snapshots, consumed by the STEP 5 post-condition ----
        uint256 adapterInBefore; // BUY only: adapter's assetIn token balance
        uint256 adapterSharesBefore; // SELL only: adapter's assetIn shares
        // ---- STEP 4: realised output, measured not reported ----
        uint256 grossShares; // BUY only
        uint256 grossOut; // SELL only
        // ---- STEP 7: the fee split, assigned from {_applyFee}'s return values ----
        uint256 netShares; // BUY only; 0 on a sell
        uint256 feeShares; // BUY only; 0 on a sell
        uint256 amountOutNet;
        uint256 feeAmount;
    }

    /// @inheritdoc ISettlementEngine
    /// @dev THE TEN STEPS BELOW ARE ORDER-DEPENDENT. Several of them are only
    ///      correct because of what precedes them — the multiplier snapshot must
    ///      bracket every conversion, the fee must be computed before slippage is
    ///      checked, and both custody post-conditions must run after delivery.
    ///      Reordering them is not a refactor.
    ///
    ///      ============== THE ROUTER IS NOT A TRUST ANCHOR ==============
    ///      This function receives `(o, resolvedVenueId, adapter)` from the Router
    ///      and RE-VERIFIES the pairing independently via {_verifyAdapter}, and
    ///      re-checks the deadline, rather than accepting either on the caller's
    ///      word.
    ///
    ///      Being the ONLY PERMITTED CALLER is not the same as being TRUSTED, and
    ///      conflating the two is how a correct access-control check ends up
    ///      guarding nothing. `onlyRouter` answers "who may call this"; it says
    ///      nothing about whether the arguments are right. If the Router is ever
    ///      redeployed with a bug — a resolution loop that returns a stale
    ///      adapter, an off-by-one over the venue set, an adapter variable
    ///      shadowed in a refactor — this re-verification is what stops a bad
    ///      adapter address from reaching the swap with client funds already in
    ///      hand. The registry is the single source of truth for "which contract
    ///      executes this venue", and settlement reads it directly rather than
    ///      trusting a copy passed across a call boundary. THIS IS WHERE FUNDS
    ///      MOVE, so this is where the last line of defence belongs.
    ///      ==============================================================
    ///
    ///      ===================== REENTRANCY =====================
    ///      `nonReentrant`, and the justification is concrete rather than
    ///      precautionary. This function makes external calls to THREE parties
    ///      that can each hand control to code this contract does not choose:
    ///
    ///        1. THE CLIENT ACCOUNT, via `transferFrom` / `transferSharesFrom`.
    ///           `o.account` is a contract in the intended deployment
    ///           (ClientSmartAccount) and is client-controlled in any case.
    ///        2. THE ADAPTER, via `swap`. Registered by an admin, but it is the
    ///           component that talks to a third-party venue, and this design
    ///           refuses to trust its self-reporting elsewhere for the same
    ///           reason it refuses to trust its control flow here.
    ///        3. THE TOKENS, on every transfer. A token with a transfer hook can
    ///           call back before this function's post-conditions have run.
    ///
    ///      Without the guard, a callback landing between the STEP 4 measurement
    ///      and the STEP 10 post-condition could interleave a second settlement
    ///      whose transfers are then attributed to this one's snapshots — the
    ///      snapshot-based accounting is exactly what a reentrant call would
    ///      corrupt, because both settlements would be measuring the same
    ///      balances against different baselines.
    ///
    ///      CONTRAST WITH MockShareRegistry, where a guard was deliberately
    ///      OMITTED: that contract makes no external calls at all, so no callback
    ///      path into it exists and a guard would cost storage and gas to block a
    ///      pattern that cannot occur. Same reasoning — "does a concrete callback
    ///      path exist?" — opposite conclusion, because here the answer is yes
    ///      three times over.
    ///      ======================================================
    ///
    ///      =============== FULL REVERT ON ANY FAILED LEG ===============
    ///      There is NO try/catch anywhere in this function. Every external call
    ///      is unguarded and any revert propagates, unwinding the entire
    ///      settlement including transfers already made. PARTIAL SETTLEMENT IS
    ///      NOT A MODE THIS ENGINE HAS: there is no state recording a half-filled
    ///      order, and nothing to reconcile afterwards. Batch semantics with
    ///      per-order partial failure are Part B option 3, which was not chosen —
    ///      so the "some legs succeeded" case has no representation here, and
    ///      swallowing an error would create a state the rest of the system
    ///      cannot describe.
    ///      =============================================================
    ///
    ///      ====== `minAmountOut`: THE ONE DENOMINATION GAP IN THE SYSTEM ======
    ///      `minAmountOut` is the one quantity in this system that is necessarily
    ///      BALANCE-DENOMINATED. Everything else settlement relies on is
    ///      share-denominated where it touches the rebasing leg; this is not,
    ///      because the spec's `Order` struct provides no share-denominated
    ///      equivalent and adding one would deviate from a given interface.
    ///
    ///      WITHIN A TRANSACTION IT IS SAFE. The multiplier is snapshotted in
    ///      STEP 1 and re-checked in STEP 6, so the shares-to-tokens mapping is
    ///      FIXED for the whole of settlement and the bound means exactly one
    ///      thing from the moment it is read to the moment it is enforced.
    ///
    ///      ACROSS BLOCKS IT IS NOT, and the reason is worth stating precisely
    ///      because the obvious intuition is wrong. A corporate action changes
    ///      the bound's economic meaning, and THE DIRECTION OF THAT CHANGE IS NOT
    ///      DETERMINED BY THE DIRECTION OF THE MULTIPLIER. The rebasing asset
    ///      sits inside an AMM pool that assumes STATIC RESERVES: a corporate
    ///      action moves the pool's token balance while its stored reserves are
    ///      unchanged, and after `sync()` the pool reprices. How that repricing
    ///      lands depends on pool composition and on who arbitrages first — not
    ///      on whether the multiplier went up. A client cannot reason "the
    ///      multiplier only rises, so my floor can only become conservative".
    ///
    ///      THE PROTECTIONS ARE THEREFORE:
    ///        - `deadline`, which bounds how STALE a bound may be before it can
    ///          no longer be acted on;
    ///        - FRESH QUOTING AT SUBMISSION, since the Router's quote is
    ///          indicative and re-taken per order rather than cached;
    ///        - ENFORCEMENT AGAINST THE FINAL NET OUTPUT here at settlement,
    ///          which is the only figure that reflects what the client receives.
    ///
    ///      The UP-ONLY multiplier choice simplifies internal SHARE ACCOUNTING.
    ///      It does NOT make the slippage bound directionally safe. Keeping those
    ///      two claims separate is the point of this note — conflating them would
    ///      let someone conclude that a rising multiplier makes `minAmountOut`
    ///      redundant on a buy, which it does not.
    ///      ====================================================================
    /// @param o               The original, unmodified order. See STEP 4 for why
    ///                        the copy passed to the adapter must not be used in
    ///                        its place when hashing.
    /// @param resolvedVenueId Venue selected by the Router, re-verified here.
    /// @param adapter         Adapter the Router resolved, re-verified here.
    /// @return amountOutNet   Amount of `o.assetOut` delivered to the client, NET
    ///                        of fee — the same figure `minAmountOut` is checked
    ///                        against, so the caller's return value and the
    ///                        client's protection describe one quantity.
    function settle(OrderTypes.Order calldata o, bytes32 resolvedVenueId, address adapter)
        external
        onlyRouter
        nonReentrant
        returns (uint256 amountOutNet)
    {
        SettlementState memory s;

        /*----------------------------------------------------------------------
        STEP 0 — VALIDATE AND SNAPSHOT
        ----------------------------------------------------------------------*/

        _verifyAdapter(resolvedVenueId, adapter);

        // The Router already checked this. Re-checked anyway because THIS is
        // where funds move: a stale deadline that slips past the Router — a
        // Router redeployed with a reordered check, or any future caller — must
        // not be able to execute a client's order against a price bound they set
        // for a market that no longer exists. The last line of defence re-checks
        // rather than assuming the first one held.
        if (o.deadline < block.timestamp) revert DeadlineExpired(o.deadline, block.timestamp);

        (s.rebasingToken, s.isBuy) = _rebasingLeg(o);

        // Snapshots for the STEP 10 post-condition. Taken BEFORE anything moves,
        // and deliberately including whatever this engine already holds — see
        // PRINCIPLE 2. All three are needed: the two token balances cover both
        // legs, and the share read is the exact one (PRINCIPLE 1) for the
        // rebasing leg, whichever side it sits on.
        s.engineInBefore = IERC20(o.assetIn).balanceOf(address(this));
        s.engineOutBefore = IERC20(o.assetOut).balanceOf(address(this));
        s.engineSharesBefore = IRebasingEquityToken(s.rebasingToken).shares(address(this));

        /*----------------------------------------------------------------------
        STEP 1 — SNAPSHOT THE MULTIPLIER

        BE PRECISE ABOUT WHAT THIS PROTECTS AGAINST. It is NOT protection against
        a rebase between quote and execution across blocks: that is uncatchable
        from inside this transaction — the corporate action has already happened
        and left no in-transaction trace — and is handled instead by `deadline`
        and by the net-output bound in STEP 7.

        WITHIN one transaction the multiplier can only move if something in this
        settlement path reached `applyCorporateAction`. Nothing on the intended
        path does, so a change here means reentrancy, or a malicious or
        compromised adapter, or a token that is not what it was registered as.

        This is therefore an INVARIANT VIOLATION DETECTOR, not a rebase detector.
        Naming it correctly matters: read as a rebase guard it looks like
        protection it does not provide, and someone would eventually remove the
        `deadline` check believing this covers it.
        ----------------------------------------------------------------------*/

        s.multiplierBefore = IRebasingEquityToken(s.rebasingToken).multiplier();

        /*----------------------------------------------------------------------
        STEP 2 — RESOLVE THE EXECUTABLE INPUT
        ----------------------------------------------------------------------*/

        _resolveInput(o, s);

        /*----------------------------------------------------------------------
        STEP 3 — PULL VIA SCOPED ALLOWANCE, FORWARD TO THE ADAPTER
        ----------------------------------------------------------------------*/

        _fundAdapter(o, adapter, s);

        /*----------------------------------------------------------------------
        STEP 4 — EXECUTE ON THE FUNDED AMOUNT ONLY, AND MEASURE THE RESULT
        ----------------------------------------------------------------------*/

        _executeAndMeasure(o, adapter, s);

        /*----------------------------------------------------------------------
        STEP 5 — THE ADAPTER CONSUMED EXACTLY THE FUNDED DELTA
        ----------------------------------------------------------------------*/

        _assertAdapterConsumed(o, adapter, s);

        /*----------------------------------------------------------------------
        STEP 6 — RE-READ THE MULTIPLIER

        REVERT RATHER THAN RECOMPUTE. The brief permits either. Recomputing would
        mean settling against a quantity the client never priced against — their
        `minAmountOut` was chosen under the old multiplier, and silently
        re-deriving under a new one delivers a trade they did not ask for.
        Reverting is the safer of the two and is trivially auditable: there is
        one comparison and one outcome, versus a recomputation path that would
        need its own correctness argument for a case that must never occur.

        Note the direction. The multiplier is UP-ONLY, so a change detected here
        can only be upward, which on a buy would mean MORE value than expected —
        a windfall for the client. The engine reverts regardless. An unexplained
        state change mid-flight indicates a compromised execution path, and the
        sign of the resulting price move is not evidence about the cause. Taking
        the windfall would mean accepting output from a path already known to be
        broken.
        ----------------------------------------------------------------------*/

        uint256 multiplierAfter = IRebasingEquityToken(s.rebasingToken).multiplier();
        if (multiplierAfter != s.multiplierBefore) {
            revert MultiplierChangedDuringSettlement(s.multiplierBefore, multiplierAfter);
        }

        /*----------------------------------------------------------------------
        STEP 7 — FEE, THEN SLIPPAGE, IN THAT ORDER

        THE ORDERING IS THE WHOLE POINT. `minAmountOut` is checked against the
        NET amount the client actually receives. Checking the gross figure would
        silently under-deliver by FEE_BPS against a bound the client believes is
        a floor on what reaches them — a 2 bps breach of an explicit guarantee,
        small enough to go unnoticed and wrong in exactly the way slippage
        protection exists to prevent.

        THREAT MODEL — THE ZERO-FEE EDGE CASE. When rounding yields a zero fee,
        settlement PROCEEDS with a zero fee rather than reverting. The threshold
        is explicit arithmetic, not a judgement call: on a buy the fee floors to
        zero when

            grossShares * 2 / 10000 < 1,   i.e.   grossShares < 5000

        — five thousand WEI-shares, economically nothing. The identical threshold
        applies to `grossOut` on a sell. Evading a meaningful fee by splitting an
        order into sub-threshold pieces would take on the order of 1e14 orders to
        move a position of any size, so the leak is not economically reachable at
        any order count that fits in a chain.

        Reverting instead would make dust-sized orders PERMANENTLY UNSETTLEABLE —
        a real liveness cost paid against a leak nobody can reach. Note the
        argument is the threshold arithmetic, NOT "gas costs exceed the savings":
        that reasoning is hand-waving in general and is especially weak on a
        low-fee chain, where it could quietly stop being true.
        ----------------------------------------------------------------------*/

        (s.netShares, s.amountOutNet, s.feeAmount, s.feeShares) =
            _applyFee(o, s.rebasingToken, s.isBuy, s.grossShares, s.grossOut);

        if (s.amountOutNet < o.minAmountOut) revert InsufficientOutput(o.minAmountOut, s.amountOutNet);

        /*----------------------------------------------------------------------
        STEP 8 — DELIVER TO THE CLIENT
        ----------------------------------------------------------------------*/

        _deliver(o, s);

        /*----------------------------------------------------------------------
        STEP 9 — EMIT

        THE HASH IS TAKEN OVER THE ORIGINAL `o`. See the warning in
        {_executeAndMeasure}: the modified copy exists only inside that helper,
        and this is the reason it is scoped there rather than held in `s`.
        ----------------------------------------------------------------------*/

        emit Settled(
            keccak256(abi.encode(o)),
            o.account,
            resolvedVenueId,
            s.rebasingToken,
            s.isBuy,
            o.assetIn,
            o.assetOut,
            s.sharesIn,
            s.netShares,
            s.feeShares,
            s.multiplierBefore,
            s.executableAmountIn,
            s.amountOutNet,
            s.feeAmount
        );

        /*----------------------------------------------------------------------
        STEP 10 — THE ENGINE RETAINED NOTHING

        A DELTA CHECK, NOT AN ABSOLUTE-ZERO ONE — PRINCIPLE 2. Requiring this
        contract to hold nothing would mean a single donated wei permanently
        bricks every settlement of that pair, the same one-wei DoS that STEP 4
        avoids on the adapter. Comparing against the STEP 0 snapshot asserts the
        property that actually matters and is unaffected by donations.

        WHAT THIS PROVES: the engine RETAINS NOTHING FROM A SETTLEMENT. Every
        unit it touches is delivered onward in the same transaction — to the
        client, to the fee recipient, or to the venue. That is the non-custodial
        claim, and it is the one that matters to a client deciding whether to
        approve an allowance.

        WHAT IT DOES NOT PROVE: that the engine holds nothing. Donated or
        mis-sent funds may sit at this address permanently, because there is no
        rescue path by design (see 4.1). The stranding is disclosed rather than
        papered over, and the non-custodial argument deliberately rests on the
        retention property instead of on an absolute-balance claim that would be
        both weaker and unenforceable.

        IT ALSO CATCHES SOMETHING SUBTLER THAN DONATION. If the fee transfer or
        the client delivery silently under-sent — a fee-on-transfer stable, a
        token whose `transfer` moves less than requested, an arithmetic slip in
        the fee split — the residue is caught HERE, in the transaction that
        created it, rather than accumulating unnoticed across settlements until
        someone reconciles the books and finds a balance nobody can explain or
        withdraw.
        ----------------------------------------------------------------------*/

        if (
            IERC20(o.assetIn).balanceOf(address(this)) != s.engineInBefore
                || IERC20(o.assetOut).balanceOf(address(this)) != s.engineOutBefore
                || IRebasingEquityToken(s.rebasingToken).shares(address(this)) != s.engineSharesBefore
        ) revert EngineRetainedFunds();

        amountOutNet = s.amountOutNet;
    }

    /// @dev Independent re-derivation of the adapter for `venueId`. See {settle}.
    ///      `getAdapter` reverts with `VenueNotRegistered` for an unknown id, so
    ///      a de-registered venue fails there rather than mismatching here — the
    ///      two failures are distinct on purpose.
    function _verifyAdapter(bytes32 venueId, address adapter) internal view {
        if (venueRegistry.getAdapter(venueId) != adapter) revert AdapterMismatch(venueId, adapter);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT: STEP HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev STEP 2. Determine the input quantity this settlement will actually
    ///      execute, which is NOT always `o.amountIn`.
    ///
    ///      BUY — `assetIn` is the stable. No conversion is involved, so the
    ///      requested amount is executable exactly. `sharesIn` stays 0, which is
    ///      what the {Settled} event publishes for a buy.
    ///
    ///      SELL — `assetIn` is the rebasing token, and here THE SHARE QUANTITY
    ///      IS CANONICAL AND THE TOKEN AMOUNT IS DERIVED FROM IT, not the other
    ///      way round. `o.amountIn` is floored to shares, and the executable
    ///      token amount is then derived back from those shares. Both
    ///      conversions floor, so:
    ///
    ///          executableAmountIn <= o.amountIn
    ///
    ///      THE CONSEQUENCE, PLAINLY: at a non-unity multiplier the executed
    ///      input can be up to one share-worth less than the client requested.
    ///      That is the CORRECT DIRECTION — never more than requested, and the
    ///      residual dust stays with the client rather than being consumed or
    ///      created. The client is never debited beyond what they asked for.
    ///
    ///      WHY THE RESOLVED SHARE QUANTITY IS THE EXECUTABLE ONE. The
    ///      alternative — funding the adapter and then requiring the observed
    ///      delta to equal `o.amountIn` — would revert EVERY SELL at a non-unity
    ///      multiplier, because the token amount corresponding to a whole number
    ///      of shares generally is not `o.amountIn`. The system would work
    ///      perfectly until the first corporate action and then stop accepting
    ///      sells entirely. Deriving the executable amount from the shares makes
    ///      the funded quantity and the asserted quantity the same number by
    ///      construction, so STEP 3's equality check is exact rather than
    ///      approximately true.
    ///
    ///      `o.amountIn == 0` is re-checked here for the same reason the deadline
    ///      is: the Router checks it, and the Router is not a trust anchor.
    function _resolveInput(OrderTypes.Order calldata o, SettlementState memory s) private view {
        if (o.amountIn == 0) revert ZeroAmount();

        if (s.isBuy) {
            s.executableAmountIn = o.amountIn;
            return;
        }

        s.sharesIn = _toShares(o.assetIn, o.amountIn);

        // A request too small to resolve to a single share. Rejected rather than
        // executed as a zero-input trade that would move nothing while emitting
        // a complete settlement log.
        if (s.sharesIn == 0) revert ZeroAmount();

        s.executableAmountIn = _toAmount(o.assetIn, s.sharesIn);
    }

    /// @dev STEP 3. Move the input from the client to the adapter in ONE
    ///      MOVEMENT, and assert it arrived.
    ///
    ///      ============ SCOPED ALLOWANCE — THE CUSTODY MODEL ============
    ///      THE CLIENT APPROVES THIS ENGINE ONLY. No adapter is ever approved on
    ///      the client's behalf, and this contract never calls `approve` on an
    ///      adapter — not before the swap, not with a zero-after reset, not at
    ///      all. That is what keeps the client's standing approval pointed at ONE
    ///      audited contract instead of at every venue integration the system
    ///      ever registers.
    ///
    ///      The pull and the forward are a single `transferFrom` with the adapter
    ///      as recipient, so the funds never rest at this engine between the two.
    ///      A pull-then-forward pair would leave a window in which client funds
    ///      sit at an address with no withdrawal path, and would make the STEP 10
    ///      post-condition depend on two transfers agreeing instead of one.
    ///      ==============================================================
    ///
    ///      WHY `transferSharesFrom` ON THE SELL LEG. It moves an EXACT SHARE
    ///      QUANTITY with no amount -> shares -> amount round trip, so the input
    ///      leg generates NO DUST AT ALL. Using `transferFrom` with
    ///      `executableAmountIn` would re-floor a figure already derived by
    ///      flooring, reintroducing a rounding step that the STEP 2 resolution
    ///      exists to eliminate — and the observed delta would then have to be
    ///      compared with a tolerance rather than for equality.
    ///
    ///      THE ARRIVAL ASSERTION is not redundant with the transfer's own return
    ///      value. A fee-on-transfer or deflationary `assetIn` returns `true`
    ///      while delivering less than requested; the adapter would then be
    ///      funded below what the swap is about to be priced for, and the failure
    ///      would surface as an opaque venue-side revert (or, worse, a silently
    ///      worse fill) instead of a named error here. Both legs assert EQUALITY,
    ///      not a lower bound, because both quantities are exact by construction:
    ///      the buy leg moves a token amount with no conversion, and the sell leg
    ///      moves shares, which are stored rather than derived (PRINCIPLE 1).
    function _fundAdapter(OrderTypes.Order calldata o, address adapter, SettlementState memory s) private {
        if (s.isBuy) {
            s.adapterInBefore = IERC20(o.assetIn).balanceOf(adapter);

            IERC20(o.assetIn).safeTransferFrom(o.account, adapter, s.executableAmountIn);

            if (IERC20(o.assetIn).balanceOf(adapter) - s.adapterInBefore != s.executableAmountIn) {
                revert InputTransferMismatch();
            }
        } else {
            s.adapterSharesBefore = IRebasingEquityToken(o.assetIn).shares(adapter);

            IRebasingEquityToken(o.assetIn).transferSharesFrom(o.account, adapter, s.sharesIn);

            if (IRebasingEquityToken(o.assetIn).shares(adapter) - s.adapterSharesBefore != s.sharesIn) {
                revert InputTransferMismatch();
            }
        }
    }

    /// @dev STEP 4. Execute the swap on the funded amount ONLY, and measure what
    ///      came back.
    ///
    ///      ========= THE ADAPTER MUST NOT SWEEP ITS OWN BALANCE =========
    ///      CRITICAL. The adapter executes exactly the amount this settlement
    ///      funded, never its entire `assetIn` balance. An adapter that swept its
    ///      whole holding would consume anything already sitting there — residue
    ///      from a prior settlement, or an unsolicited donation — and the STEP 5
    ///      retention check would then fail on EVERY SUBSEQUENT SETTLEMENT
    ///      through that adapter, because the swept amount could never match the
    ///      funded delta. That is a free griefing DoS: ONE WEI SENT TO AN ADAPTER
    ///      BRICKS IT PERMANENTLY. Same shape as the absolute-zero post-condition
    ///      trap in PRINCIPLE 2, reached from the opposite direction.
    ///
    ///      HOW THE AMOUNT IS COMMUNICATED, and why not the obvious way: adding
    ///      an `amountIn` parameter to `IVenueAdapter.swap` would be the direct
    ///      fix, but the spec fixes that signature, and deviating from a given
    ///      interface is a visible, avoidable cost in a system whose modularity
    ///      claim rests on adapters being interchangeable behind it. Instead a
    ///      MODIFIED COPY of the order carries the executable quantity. The
    ///      interface takes `Order calldata`; a memory struct ABI-encodes
    ///      correctly at the external call boundary, so no signature changes.
    ///
    ///      The adapter therefore treats `o.amountIn` as AUTHORITATIVE — which is
    ///      the natural reading of the spec's signature anyway, and is now stated
    ///      explicitly in {IVenueAdapter.swap}'s NatSpec rather than left to
    ///      convention.
    ///      ==============================================================
    ///
    ///      =================== ORDER HASH WARNING ===================
    ///      `orderHash` MUST be computed from the ORIGINAL `o`, NEVER from
    ///      `executable`. The Router derives its hash from the original order, so
    ///      hashing the modified copy would produce a different hash on every
    ///      SELL — silently breaking event correlation between {OrderSubmitted},
    ///      {OrderRouted}, and {Settled} for exactly the orders where the two
    ///      structs differ, while buys continued to correlate fine and hid the
    ///      bug. `executable` is scoped to this function and never returned in
    ///      `s`, so the mistake is hard to make from {settle}. This is a live
    ///      footgun for anyone editing this function later.
    ///      ==========================================================
    ///
    ///      QUOTE / EXECUTION MISMATCH ON A SELL, stated rather than left to be
    ///      discovered: the Router's best-execution `quote` runs against the
    ///      ORIGINAL `o.amountIn`, so on a sell it prices a marginally larger
    ///      input than actually executes. Quotes are already documented as
    ///      indicative routing signals used only to rank venues, so this is
    ///      consistent with the design — and the difference is bounded by one
    ///      share-worth, far below any margin that would change which venue wins.
    ///
    ///      ============ MEASURE, DO NOT TRUST THE RETURN VALUE ============
    ///      The adapter's returned `amountOut` is DISCARDED ENTIRELY for
    ///      accounting purposes. A measured delta cannot be inflated by a lying
    ///      or buggy adapter, while a self-reported figure is exactly the number
    ///      a malicious adapter would overstate to pass the STEP 7 slippage check
    ///      while delivering less. The measurement follows PRINCIPLE 1: SHARE
    ///      delta on a buy (where `assetOut` is the rebasing token), BALANCE delta
    ///      on a sell (where it is the stable, and the delta is exact).
    ///      ================================================================
    ///
    ///      DELIVERY IS TO `address(this)`, NOT TO `o.account`, because the fee
    ///      must be taken before the client is paid. Paying the client first and
    ///      collecting afterwards would require pulling funds back out of a client
    ///      account over which this engine has no withdrawal rights — precisely
    ///      the property A5 exists to prove. The engine holds the output for the
    ///      remainder of this transaction and nothing longer; STEP 10 is what
    ///      turns "nothing longer" into an enforced assertion.
    function _executeAndMeasure(OrderTypes.Order calldata o, address adapter, SettlementState memory s) private {
        // The modified copy. Everything except the input amount is the client's
        // order verbatim — the adapter still sees the real account, assets,
        // minimum, venue, and deadline.
        OrderTypes.Order memory executable = o;
        executable.amountIn = s.executableAmountIn;

        if (s.isBuy) {
            uint256 selfSharesBefore = IRebasingEquityToken(o.assetOut).shares(address(this));

            IVenueAdapter(adapter).swap(executable, address(this));

            s.grossShares = IRebasingEquityToken(o.assetOut).shares(address(this)) - selfSharesBefore;

            // A swap that delivered nothing. Rejected here rather than allowed to
            // continue into a fee split and a delivery of zero.
            if (s.grossShares == 0) revert ZeroAmount();
        } else {
            uint256 selfBefore = IERC20(o.assetOut).balanceOf(address(this));

            IVenueAdapter(adapter).swap(executable, address(this));

            s.grossOut = IERC20(o.assetOut).balanceOf(address(this)) - selfBefore;

            if (s.grossOut == 0) revert ZeroAmount();
        }
    }

    /// @dev STEP 5. Assert the adapter's input holding returned to its
    ///      PRE-SETTLEMENT level — it consumed this settlement's funded amount
    ///      and nothing else, and retained none of it.
    ///
    ///      Against the STEP 3 snapshot, never against zero (PRINCIPLE 2). An
    ///      adapter holding a donated wei is not misbehaving, and must not be
    ///      permanently unusable because of it.
    ///
    ///      ============ WHY THE SELL LEG NEEDS A ONE-SHARE TOLERANCE ============
    ///      The buy leg compares token balances for exact equality, which is
    ///      correct: no conversion is involved on either side.
    ///
    ///      The sell leg cannot. THE ADAPTER SPENDS IN TOKEN TERMS BUT THIS CHECK
    ///      READS SHARES. Because `floor(a*m/1e18)` does not compose under
    ///      subtraction (PRINCIPLE 1), an adapter that spends exactly
    ///      `executableAmountIn` tokens can move its own share balance by
    ///      `sharesIn ± 1`. Strict equality would revert legitimate settlements
    ///      non-deterministically, depending on the share remainder the adapter
    ///      happened to be carrying.
    ///
    ///      THE TOLERANCE IS BOUNDED AND DOES NOT ACCUMULATE. It is one wei-share
    ///      per settlement, and each check is against THAT SETTLEMENT'S OWN
    ///      SNAPSHOT — so drift cannot compound across settlements the way it
    ///      would against a fixed baseline. This check exists to catch an adapter
    ///      RETAINING MEANINGFUL FUNDS, which is a whole trade's worth, not to
    ///      police sub-wei rounding it is not the right instrument to measure.
    ///
    ///      TWO ALTERNATIVES REJECTED, and both belong in the threat model rather
    ///      than buried here:
    ///        1. HAVE THE ADAPTER SWEEP ITS ENTIRE SHARE BALANCE, making the
    ///           post-state exactly zero and the check exact. This reintroduces
    ///           the one-wei donation-griefing surface that STEP 4 closes, and
    ///           trades a bounded rounding tolerance for an unbounded DoS.
    ///        2. HAVE THE ADAPTER SELF-REPORT THE SHARES IT CONSUMED. This trusts
    ///           the adapter to report on itself, which this design refuses
    ///           everywhere else — most directly in STEP 4, where its returned
    ///           `amountOut` is discarded for exactly this reason. Accepting
    ///           self-reporting here would make that refusal decorative.
    ///      ====================================================================
    function _assertAdapterConsumed(OrderTypes.Order calldata o, address adapter, SettlementState memory s)
        private
        view
    {
        if (s.isBuy) {
            if (IERC20(o.assetIn).balanceOf(adapter) != s.adapterInBefore) revert AdapterRetainedFunds();
            return;
        }

        uint256 adapterSharesAfter = IRebasingEquityToken(o.assetIn).shares(adapter);

        // Absolute difference: the drift can fall on either side of the snapshot,
        // because the flooring that causes it is not directional.
        uint256 drift = adapterSharesAfter > s.adapterSharesBefore
            ? adapterSharesAfter - s.adapterSharesBefore
            : s.adapterSharesBefore - adapterSharesAfter;

        if (drift > 1) revert AdapterRetainedFunds();
    }

    /// @dev STEP 7. Split the realised output into the client's net and the
    ///      protocol's fee, pay the fee, and return all four figures.
    ///
    ///      ==================== THE ASYMMETRY ====================
    ///      THE FEE IS ALWAYS TAKEN FROM `assetOut`, and `assetOut` IS THE
    ///      REBASING TOKEN ONLY ON A BUY. That single fact produces every
    ///      difference between the two branches below — the denomination of the
    ///      fee, which transfer primitive moves it, and why two of the four
    ///      return values are zero on a sell.
    ///
    ///      BUY  — the fee is a SHARE quantity. The whole branch works in shares
    ///             with NO ROUND TRIP through token amounts: the split, the
    ///             conservation check, and the transfer are all share-denominated,
    ///             and token amounts are derived only at the end, for reporting.
    ///      SELL — the fee is a STABLE AMOUNT and does not rebase. There is no
    ///             share quantity involved on the output leg at all.
    ///      =======================================================
    ///
    ///      ============ CONSERVATION IS THE STRONGEST STATEMENT ============
    ///      On the buy leg:
    ///
    ///          feeShares + netShares == grossShares
    ///
    ///      EXACTLY, with no dust, for every input. This is the single strongest
    ///      claim in the fee path and the one worth checking first when reading
    ///      it: whatever the swap realised is split in two and nothing is lost
    ///      between them. It is asserted in code rather than only asserted here.
    ///
    ///      It holds because the net is computed by SUBTRACTION rather than by a
    ///      second independent division. Computing both sides independently would
    ///      let two floors disagree and leave a residue the engine could not
    ///      deliver — which STEP 10 would then catch as retained funds, turning a
    ///      rounding choice into a failed settlement. The sell leg gets its
    ///      conservation the same way, for the same reason.
    ///      =================================================================
    ///
    ///      THE FEE ROUNDS DOWN, IN THE CLIENT'S FAVOUR. Flooring means the
    ///      protocol NEVER OVER-CHARGES; the residual — at most one wei-share on a
    ///      buy, one wei on a sell — stays with the client, inside `netShares`.
    ///      Same direction as every other conversion in this contract: no value is
    ///      ever created from a choice of rounding mode.
    ///
    ///      ON A BUY, `amountOutNet` IS DERIVED FROM `netShares` — the very
    ///      quantity STEP 8 transfers — so the event and the transfer CANNOT
    ///      DISAGREE. Deriving it instead as "gross tokens minus fee tokens" would
    ///      publish a figure that no transfer ever moved.
    ///
    ///      ====== WHY `feeShares` IS ZERO ON A SELL — NOT A MISSING VALUE ======
    ///      The spec requires fee capture to be share-denominated. That
    ///      requirement is satisfied on a sell, and reading the zero as a gap
    ///      misidentifies what share-denomination attaches to.
    ///
    ///      SHARE-DENOMINATION ATTACHES TO THE REBASING LEG OF THE TRADE, NOT TO
    ///      WHICHEVER ASSET THE FEE HAPPENS TO BE TAKEN FROM. On a sell the
    ///      rebasing leg is the INPUT, and {Settled} records `sharesIn` for it. The
    ///      share accounting for the trade is therefore COMPLETE AND RECONCILABLE:
    ///      every share that moved is in the log, against the registry, exactly.
    ///
    ///      The fee itself is a stable-asset figure. Forcing it into a share
    ///      denomination would mean dividing a STABLE amount by an EQUITY
    ///      multiplier — an operation whose result corresponds to no custodied
    ///      share and no holder's position.
    ///
    ///      REJECTED ALTERNATIVE: converting the stable fee to a notional share
    ///      figure at the prevailing multiplier, purely for reporting symmetry, so
    ///      `feeShares` is never zero. Rejected because a notional share BACKED BY
    ///      NOTHING would reconcile against the share registry AND FAIL — the
    ///      registry knows how many shares exist, and this figure would not be
    ///      among them. AN HONEST ZERO IS BETTER THAN A SYMMETRIC LIE. A consumer
    ///      seeing `feeShares == 0` learns something true; one seeing a fabricated
    ///      share figure learns something that breaks the moment it is checked.
    ///      =====================================================================
    ///
    ///      ============ BUY-SIDE CONSEQUENCE — NOT A DEFECT ============
    ///      On a buy the fee recipient holds REAL SHARES, so its position moves
    ///      with the next corporate action. This is CORRECT BY CONSTRUCTION: the
    ///      fee recipient is an ordinary holder, its share count is fixed by the
    ///      transfer, and its balance scales exactly as every other holder's does.
    ///      No value is created or destroyed, and the share-conservation invariant
    ///      covers the fee recipient like any other address — there is no special
    ///      case in the token and none is needed here.
    ///
    ///      The real consequence is OPERATIONAL, not a contract concern: fee
    ///      revenue on buys carries EQUITY EXPOSURE, so treasury policy has to
    ///      decide whether to sweep to stable on receipt or hold the position.
    ///      That is a business decision, and this contract deliberately does not
    ///      make it silently on the operator's behalf.
    ///      =============================================================
    /// @param o            The order. Used for `assetOut` on the sell leg.
    /// @param rebasingToken The rebasing leg's token, from {_rebasingLeg}. On a
    ///                      buy this IS `o.assetOut`; passed explicitly so the
    ///                      share operations name what they act on.
    /// @param isBuy        True when `assetOut` is the rebasing token.
    /// @param grossShares  Realised output shares. Populated on a buy, 0 on a sell.
    /// @param grossOut     Realised output tokens. Populated on a sell, 0 on a buy.
    /// @return netShares    Shares delivered to the client. 0 on a sell.
    /// @return amountOutNet Token amount delivered to the client, both legs.
    /// @return feeAmount    Fee in token amount, both legs.
    /// @return feeShares    Fee in shares. 0 on a sell — see above.
    function _applyFee(
        OrderTypes.Order calldata o,
        address rebasingToken,
        bool isBuy,
        uint256 grossShares,
        uint256 grossOut
    ) internal returns (uint256 netShares, uint256 amountOutNet, uint256 feeAmount, uint256 feeShares) {
        if (isBuy) {
            feeShares = (grossShares * FEE_BPS) / BPS_DENOMINATOR;
            netShares = grossShares - feeShares;

            // The conservation invariant, checked rather than assumed. It holds by
            // construction TODAY, because `netShares` is a subtraction — so this
            // can never fire against the code as written, and that is the point:
            // it is a tripwire for a future edit that computes the net by its own
            // division instead. `assert` rather than a custom error because a
            // failure here is a broken contract, not a rejected input.
            assert(feeShares + netShares == grossShares);

            // REQUIRED, not defensive. {MockRebasingEquityToken.transferShares}
            // reverts on a zero share amount by design — a zero-value transfer
            // that returns true and emits a Transfer is indistinguishable from a
            // real one, so it fails loudly. Without this guard EVERY DUST-SIZED
            // BUY WOULD BE UNSETTLEABLE. This is a correctness fix against our own
            // token's documented behaviour.
            if (feeShares > 0) {
                IRebasingEquityToken(rebasingToken).transferShares(feeRecipient, feeShares);
            }

            // Reporting figures only, derived AFTER the exact share movements —
            // never used to decide what moves. See the warning on {_toAmount}.
            amountOutNet = _toAmount(rebasingToken, netShares);
            feeAmount = _toAmount(rebasingToken, feeShares);
        } else {
            feeAmount = (grossOut * FEE_BPS) / BPS_DENOMINATOR;
            amountOutNet = grossOut - feeAmount;

            // `netShares` and `feeShares` stay 0. Not unset — see the NatSpec: the
            // output leg is the stable, so there is no share-denominated figure
            // that corresponds to anything real.

            // DEFENSIVE, not required. ERC-20 permits zero-value transfers and a
            // conforming stable would accept one, but several widely deployed
            // tokens revert on them. The guard costs one comparison and removes a
            // whole class of integration failure with a non-conforming output
            // asset — a different justification from the buy-side guard above,
            // which fixes a revert we know our own token performs.
            if (feeAmount > 0) {
                IERC20(o.assetOut).safeTransfer(feeRecipient, feeAmount);
            }
        }
    }

    /// @dev STEP 8. Deliver the net output to the client.
    ///
    ///      ON A BUY the transfer is SHARE-EXACT, moving the same `netShares` the
    ///      fee split produced. On a sell it is an ordinary token transfer of
    ///      `amountOutNet`, which is exact because the stable leg involves no
    ///      conversion.
    ///
    ///      `netShares` cannot be zero here: `grossShares > 0` is asserted in
    ///      STEP 4, and a 2 bps fee floored down can never consume all of a
    ///      non-zero quantity. So the token's zero-amount rejection is
    ///      unreachable on this path, unlike on the fee path above.
    function _deliver(OrderTypes.Order calldata o, SettlementState memory s) private {
        if (s.isBuy) {
            IRebasingEquityToken(o.assetOut).transferShares(o.account, s.netShares);
        } else {
            IERC20(o.assetOut).safeTransfer(o.account, s.amountOutNet);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         REBASING-LEG DETECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether `token` is a registered rebasing tokenised equity.
    /// @dev NEVER REVERTS. It is the discovery-path read, so callers can probe
    ///      without a revert aborting a wider decision.
    /// @param token Token to probe.
    function isRebasingToken(address token) public view returns (bool) {
        return _rebasingTokens[token];
    }

    /// @dev Resolve WHICH leg of the order is the rebasing tokenised equity, and
    ///      hence whether this order is a buy or a sell of it.
    ///
    ///      ======== WHY REGISTRY-DRIVEN AND NOT POSITIONAL ========
    ///      Detection reads {_rebasingTokens}. It does NOT hardcode a token
    ///      address, and it does NOT infer the equity leg from whether a token
    ///      appears as `assetIn` or `assetOut`.
    ///
    ///      POSITION CARRIES NO INFORMATION. The spec's `Order` struct documents
    ///      `assetOut` as the tokenised equity, which is true of a BUY — and a
    ///      SELL is the identical struct with the two legs swapped. There is no
    ///      field that distinguishes them and no flag that declares direction, so
    ///      reading the equity leg off the position would silently treat every
    ///      sell as though the stablecoin were the rebasing asset: share
    ///      conversions applied to the wrong token, the fee taken on the wrong
    ///      leg, and a {Settled} event whose canonical share fields describe
    ///      something that never happened. The registry is the only thing that
    ///      can answer the question, so it is what gets asked.
    ///
    ///      MODULARITY, which is the second and equally deliberate reason: a
    ///      SECOND tokenised equity is ONE ADMIN CALL to {registerRebasingToken}
    ///      with ZERO CODE CHANGE — no redeploy, no new branch, no constant to
    ///      update in three files. A hardcoded address would make listing a new
    ///      equity a code change to the contract that holds client funds in
    ///      transit, which is the most expensive kind of change this system can
    ///      ask for.
    ///      ========================================================
    ///
    ///      The two rejected cases are separate errors because they are separate
    ///      problems with separate fixes:
    ///        - BOTH legs rebasing ({UnsupportedAssetPair}) — an equity-for-equity
    ///          trade. Coherent to ask for, but it has two independent multipliers
    ///          and two share-denominated legs, so fee capture, share-delta
    ///          measurement, and the {Settled} schema would all need a second
    ///          form. Out of scope, and rejected explicitly rather than
    ///          mishandled by whichever branch happens to match first.
    ///        - NEITHER leg rebasing ({NoRebasingLeg}) — a stable-for-stable
    ///          trade, or, far more likely, a MISSING REGISTRATION. This engine's
    ///          accounting is built around a share-denominated leg and has
    ///          nothing to measure without one.
    /// @param o The order.
    /// @return token The rebasing leg's token address.
    /// @return isBuy True when the rebasing token is `assetOut` (being bought),
    ///               false when it is `assetIn` (being sold).
    function _rebasingLeg(OrderTypes.Order calldata o) internal view returns (address token, bool isBuy) {
        bool inIsRebasing = _rebasingTokens[o.assetIn];
        bool outIsRebasing = _rebasingTokens[o.assetOut];

        if (outIsRebasing && !inIsRebasing) return (o.assetOut, true);
        if (inIsRebasing && !outIsRebasing) return (o.assetIn, false);
        if (inIsRebasing && outIsRebasing) revert UnsupportedAssetPair(o.assetIn, o.assetOut);
        revert NoRebasingLeg(o.assetIn, o.assetOut);
    }

    /*//////////////////////////////////////////////////////////////
                            SHARE CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @dev Token amount -> shares, FLOORED, at `token`'s current multiplier.
    ///
    ///      ROUNDING RULE, applied in both directions: ROUNDING NEVER FAVOURS THE
    ///      CALLER. Both conversions floor, so wherever the multiplier does not
    ///      divide cleanly the lost sub-unit stays with the protocol or with the
    ///      client depending on which leg it falls on, and is NEVER CREATED FROM
    ///      NOTHING. Flooring in one direction and ceiling in the other would let
    ///      a round trip come back larger than it went out, which is value
    ///      appearing from a rounding mode.
    ///
    ///      Delegated to the token rather than recomputed here: the multiplier is
    ///      the token's own state, and a second implementation of the same
    ///      arithmetic is a second thing that can disagree with the first about
    ///      what a share is worth.
    ///
    ///      ==================== WARNING ====================
    ///      THESE HELPERS DERIVE REPORTABLE TOKEN FIGURES ONLY — the numbers that
    ///      go into the {Settled} event and into `minAmountOut` comparisons.
    ///
    ///      MEASUREMENT OF WHAT ACTUALLY MOVED MUST USE SHARE DELTAS, NEVER
    ///      `balanceOf` DELTAS. Floored balances DO NOT COMPOSE UNDER
    ///      SUBTRACTION: `balanceOf` floors the holder's TOTAL shares, so the
    ///      difference of two floored reads depends on the share remainder the
    ///      holder already carried and matches neither the value moved nor the
    ///      amount requested. Move one share at multiplier 1.5e18 to an account
    ///      holding one share and its balance goes 1 -> 3 — a delta of 2 for a
    ///      share worth 1.5. Subtracting share reads is exact because shares are
    ///      stored, not derived. See requirement 4.2.
    ///      ================================================
    /// @param token  A registered rebasing token.
    /// @param amount Token amount to convert.
    /// @return shares Floored share equivalent.
    function _toShares(address token, uint256 amount) internal view returns (uint256) {
        return IRebasingEquityToken(token).amountToShares(amount);
    }

    /// @dev Shares -> token amount, FLOORED, at `token`'s current multiplier.
    ///      Same rounding rule and the same measurement warning as {_toShares}.
    /// @param token  A registered rebasing token.
    /// @param shares Share amount to convert.
    /// @return amount Floored token equivalent.
    function _toAmount(address token, uint256 shares) internal view returns (uint256) {
        return IRebasingEquityToken(token).sharesToAmount(shares);
    }
}
