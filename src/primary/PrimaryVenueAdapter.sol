// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRebasingEquityToken} from "../interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../interfaces/IShareRegistry.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {PrimaryReserveVault} from "./PrimaryReserveVault.sol";

/// @title IPrimaryEquityToken
/// @notice The two members this adapter needs beyond {IRebasingEquityToken}.
/// @dev Declared here rather than added to {IRebasingEquityToken} so the shared
///      Part A interface is not widened to serve one venue. Both members already
///      exist on the concrete token; this interface only names what the primary
///      path depends on, and typing against it keeps this adapter free of a
///      compile-time dependency on a specific token implementation.
interface IPrimaryEquityToken is IRebasingEquityToken {
    /// @notice The share registry backing this token.
    function registry() external view returns (IShareRegistry);

    /// @notice `ceil(amount * 1e18 / multiplier)` — the exact inverse of the
    ///         floor conversion the settlement engine uses to derive
    ///         `executableAmountIn` from `sharesIn` on a sell.
    function amountToSharesCeil(uint256 tokenAmount) external view returns (uint256);
}

/// @title PrimaryVenueAdapter
/// @notice The 1:1 primary market as an ordinary execution venue: mint against
///         the share registry on a buy, redeem against it on a sell, at par.
/// @dev ============ THE CENTRAL ARCHITECTURE CLAIM (PART B) ============
///      PRIMARY-VS-SECONDARY ROUTING IS NOT IMPLEMENTED ANYWHERE. It falls out
///      of infrastructure that already existed before this contract did.
///
///      This adapter implements {IVenueAdapter} with no signature changes and is
///      registered in {VenueRegistry} exactly like any AMM adapter. The Router's
///      best-execution loop — written in A2 and UNMODIFIED by Part B — already
///      quotes every registered adapter and selects the highest `amountOut`:
///
///          for each registered venue:
///              try adapter.quote(assetIn, assetOut, amountIn)
///              if (candidate > best) best = candidate
///
///      See `Router._resolveVenue`. So the decision "mint at par, or buy on the
///      AMM at market price?" is that same `candidate > best` comparison, with a
///      primary quote on one side and an AMM quote on the other. NO NEW
///      COMPARISON LOGIC IS WRITTEN IN THIS CONTRACT, IN ROUTER, OR IN
///      SETTLEMENT ENGINE. Not one branch anywhere asks "is this venue the
///      primary market?" — because nothing needs to.
///
///      Two properties of the existing loop are what make this work, and both
///      predate Part B:
///        1. A quote of 0 loses to any positive quote, because `best` starts at
///           zero and the comparison is strictly-greater. So "primary cannot
///           fill this" is expressed by returning 0 — see {quote} — and needs no
///           signalling channel of its own.
///        2. A reverting quote is caught and skipped. A venue that cannot serve
///           a pair never takes the order down with it.
///      ==================================================================
///
///      ============ THE CALL-SITE ASYMMETRY — READ BEFORE EDITING ============
///      THIS IS THE SINGLE EASIEST THING IN THIS CONTRACT TO GET BACKWARDS, and
///      it governs both {quote} and {swap}.
///
///      {quote} and {swap} receive DIFFERENT REPRESENTATIONS OF THE SAME
///      UNDERLYING QUANTITY, because they are called at different points in the
///      order's life:
///
///        - ROUTER calls {quote} BEFORE the engine has resolved anything.
///        - ENGINE calls {swap} AFTER it has already resolved the order and
///          rewritten `amountIn`.
///
///      QUOTE receives the CLIENT'S ORIGINAL, UNRESOLVED `Order.amountIn`. The
///      engine has not acted on it yet. To report what the engine will actually
///      fund, {quote} must perform THE SAME FLOOR the engine is about to perform:
///
///          sharesIn = amountToShares(amountIn)          // floor, forward
///
///      SWAP's sell branch receives `order.amountIn` = the engine's MODIFIED
///      value, `executableAmountIn = floor(sharesIn * m / 1e18)` — a FLOOR'S
///      OUTPUT, not the client's original figure (see the engine's STEP 2/STEP
///      4). Recovering `sharesIn` from THAT requires the CEILING inverse:
///
///          sharesIn = amountToSharesCeil(order.amountIn)  // ceil, backward
///
///      exact because the multiplier is up-only, so `m >= 1e18`.
///
///      THESE ARE NOT THE SAME CONVERSION APPLIED TO THE SAME KIND OF INPUT.
///      {quote} floors an unresolved original amount FORWARD into shares because
///      the engine has not acted yet. {swap} ceils an already-engine-resolved
///      amount BACKWARD into shares because the engine has already acted and
///      produced a floor's output that needs inverting.
///
///      GETTING IT BACKWARDS, IN BOTH DIRECTIONS:
///        - Using the CEILING helper inside {quote} would invert a number that
///          was never floored in the first place. {quote} never receives
///          `executableAmountIn` at all, so there is nothing there to invert,
///          and the exactness proof `amountToSharesCeil` relies on would not
///          apply to its argument.
///        - Using the FLOOR helper inside {swap}'s sell branch would DOUBLE-FLOOR
///          — flooring a value that is already a floor's output — and undershoot
///          the shares this adapter actually holds, stranding a share and
///          underpaying the client.
///      ======================================================================
///
///      ============ WHY THIS NEEDS NO SPECIAL-CASING IN THE ENGINE ============
///      This adapter satisfies the EXACT SAME pre/post balance contract every
///      other venue adapter does — the one written in {IVenueAdapter} and
///      enforced by the engine's STEP 5 and STEP 10. Concretely:
///
///        - BUY: consumes only the funded delta. The engine pre-funds exactly
///          `order.amountIn` stable and this adapter forwards exactly that
///          figure to the vault, never its own balance, so its stable holding
///          returns to its pre-settlement level. STEP 5's exact-equality check
///          on the buy leg passes.
///        - SELL: recovers exactly the engine-resolved share quantity via the
///          correct inverse and redeems exactly that, so the adapter's
///          `shares(address(this))` returns to its pre-settlement level EXACTLY.
///          The engine tolerates one wei-share of drift on the sell leg; this
///          adapter uses none of that tolerance. The tolerance exists for a
///          different situation entirely — an AMM spending in TOKEN terms while
///          the check reads SHARES, where `floor(a*m/1e18)` does not compose
///          under subtraction. This adapter never spends in token terms: it
///          burns an exact share quantity, so the drift is structurally zero.
///        - Delivers the output to `recipient` (the engine) and retains nothing.
///
///      Therefore the engine's rebasing-leg detection, its measurement
///      principle, and its retention checks REQUIRE ZERO MODIFICATION to support
///      this venue. This contract is the concrete proof of the modularity claim
///      made in A3: a new venue is a deploy-and-register operation.
///      ======================================================================
///
///      ==================== DEPLOYMENT (see README) ====================
///      This adapter needs two post-deploy admin grants, and there is NO
///      circular dependency — the vault deploys standalone first:
///
///        1. deploy {PrimaryReserveVault}(stable, admin)
///        2. deploy this adapter(equityToken, stable, vault)
///        3. equityToken.grantRole(PRIMARY_ROLE, adapter)     — to mint/redeem
///        4. vault.grantRole(ADAPTER_ROLE, adapter)           — to pay redeemers
///        5. venueRegistry.setAdapter(PRIMARY_VENUE, adapter) — to be routed to
///
///      Steps 3 and 4 are ordinary admin calls. Until both are made, buys revert
///      in the token's role check and sells revert in the vault's — loudly, not
///      silently, and the {quote} path is unaffected either way.
///      ================================================================
///
///      ==================== SECURITY MODEL ====================
///      No ReentrancyGuard. The only external calls made here are to
///      `equityToken`, `stable`, and `vault`, all immutable and all trusted:
///      the token and vault are this system's own contracts, and the token's
///      registry makes no external calls at all. This adapter holds no state
///      that a reentrant caller could observe mid-update — it has no mutable
///      storage whatsoever.
///
///      No caller gate. Anyone may call {swap}, and that is safe because this
///      adapter never pulls funds: it can only spend what it already holds, and
///      the only way it comes to hold anything is a caller having funded it
///      first. An unfunded {swap} reverts in the token's `InsufficientShares` on
///      a sell, or in `SafeERC20` on a buy. A caller who funds this adapter and
///      then calls {swap} has simply performed a primary mint or redemption at
///      par with their own money, which is what the contract is for. Adding a
///      role gate would restrict the venue to one engine without closing any
///      attack, and would break the "any registered engine can route here"
///      property the venue abstraction depends on.
///      ========================================================
contract PrimaryVenueAdapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The rebasing equity token this venue mints and redeems.
    IPrimaryEquityToken public immutable equityToken;

    /// @notice The stable leg. Paid into the vault on a buy, out of it on a sell.
    IERC20 public immutable stable;

    /// @notice Where the stable reserve lives.
    /// @dev Deliberately NOT this contract. See {PrimaryReserveVault} for the
    ///      full argument: an adapter that held the reserve would still be
    ///      holding the stable it was funded with when the engine's STEP 5 check
    ///      ran, so every buy settlement would revert `AdapterRetainedFunds`.
    PrimaryReserveVault public immutable vault;

    /// @notice The share registry backing {equityToken}.
    /// @dev Read from the token at construction rather than taken as a
    ///      constructor argument. Two reasons: it cannot then disagree with the
    ///      registry the token will actually allocate against — a mismatch that
    ///      would make every {quote} an estimate of the wrong ledger — and there
    ///      is one less address for a deploy script to get wrong. Safe to cache
    ///      because the token's own `registry` is immutable.
    IShareRegistry public immutable registry;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A quantity resolved to zero shares, or a zero input was supplied.
    error ZeroAmount();

    /// @notice The vault holds less stable than this redemption requires.
    error InsufficientReserve();

    /// @notice Neither leg of the pair matches this venue's token pair.
    error UnsupportedAssetPair();

    /// @notice A constructor argument was the zero address, or had no code.
    error InvalidAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A primary issuance: stable in, newly minted shares out.
    event PrimaryMint(address recipient, uint256 sharesMinted, uint256 stableIn);

    /// @notice A primary redemption: shares burned, stable out of the vault.
    event PrimaryRedeem(address recipient, uint256 sharesBurned, uint256 stableOut);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param equityToken_ The rebasing equity token.
    /// @param stable_      The stable leg.
    /// @param vault_       The reserve vault holding stable for redemptions.
    /// @dev Every argument is checked non-zero AND `code.length > 0`. The code
    ///      check is the one that matters: all three are called as contracts, and
    ///      a plain EOA address would pass a zero-check and then make every
    ///      `quote` return 0 for reasons no error message would explain — a
    ///      silently misconfigured venue that quietly loses every routing
    ///      comparison. Failing at deployment is the only cheap place to catch it.
    constructor(address equityToken_, address stable_, address vault_) {
        if (equityToken_ == address(0) || equityToken_.code.length == 0) revert InvalidAddress();
        if (stable_ == address(0) || stable_.code.length == 0) revert InvalidAddress();
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidAddress();

        equityToken = IPrimaryEquityToken(equityToken_);
        stable = IERC20(stable_);
        vault = PrimaryReserveVault(vault_);
        registry = IPrimaryEquityToken(equityToken_).registry();
    }

    /*//////////////////////////////////////////////////////////////
                                  QUOTE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVenueAdapter
    /// @dev NEVER REVERTS. Every unmet precondition returns 0, including an
    ///      unsupported pair. There are no partial fills anywhere in this
    ///      system, so "I can fill part of this" is not a representable answer —
    ///      the only two answers are a full quote or nothing.
    ///
    ///      Returning 0 rather than reverting is not merely tidier: Router
    ///      treats both identically (skip this venue), so the two are equivalent
    ///      to the caller, and 0 is the cheaper and more honest of the two. A
    ///      revert would also be indistinguishable from a genuinely broken
    ///      adapter in the Router's `catch`.
    ///
    ///      `amountIn` HERE IS THE CLIENT'S ORIGINAL, UNRESOLVED FIGURE — the
    ///      engine has not acted yet. See the CALL-SITE ASYMMETRY note on this
    ///      contract before changing any conversion below.
    function quote(address assetIn, address assetOut, uint256 amountIn) external view returns (uint256 amountOut) {
        // ---- BUY: stable in, newly minted equity out ------------------------
        if (assetIn == address(stable) && assetOut == address(equityToken)) {
            // FLOOR, forward. This is what `mint` will be asked for, and the
            // engine's own buy path does no conversion at all on the input.
            uint256 sharesNeeded = equityToken.amountToShares(amountIn);
            if (sharesNeeded == 0) return 0;

            // The registry is the binding constraint on issuance. Checked here
            // as an ESTIMATE only — `mint` re-checks authoritatively via
            // `allocateShares`, and this figure can move between the two.
            if (registry.availableShares(address(equityToken)) < sharesNeeded) return 0;

            // NOT `amountIn`. This is the ACTUAL token-equivalent of what `mint`
            // will produce, and it can be STRICTLY LESS than `amountIn` whenever
            // `amountIn * 1e18` does not divide evenly by the multiplier.
            //
            // WHY THAT MATTERS RATHER THAN BEING A ROUNDING PEDANTRY: this
            // figure is what Router's best-execution loop compares against every
            // other venue. Returning `amountIn` verbatim would OVERSTATE
            // primary's output, and could win the comparison against an AMM
            // quote that would genuinely have delivered more. That is a
            // rounding-driven misroute — a client materially worse off — and it
            // is caused entirely by which figure is returned here.
            return equityToken.sharesToAmount(sharesNeeded);
        }

        // ---- SELL: equity in, stable out of the vault -----------------------
        if (assetIn == address(equityToken) && assetOut == address(stable)) {
            // FLOOR — and note what `amountIn` is on this path. It is the
            // client's ORIGINAL, unresolved order amount, so this call matches
            // exactly what the engine itself will floor in its STEP 2. It is NOT
            // the ceiling conversion {swap}'s sell branch performs; see the
            // CALL-SITE ASYMMETRY note.
            uint256 sharesIn = equityToken.amountToShares(amountIn);
            if (sharesIn == 0) return 0;

            // Floor, matching the payout {swap} will compute from the same share
            // quantity. Quote and settlement agree by using the same expression,
            // not by two derivations that happen to coincide.
            uint256 required = equityToken.sharesToAmount(sharesIn);

            // See the RESERVE SOLVENCY note on {swap}'s sell path. This can be
            // true purely because of an upward corporate action, with every
            // conversion in this contract correct.
            if (vault.reserveBalance() < required) return 0;

            return required;
        }

        // ---- unsupported pair -----------------------------------------------
        // Neither leg matches. Includes the equity/equity and stable/stable
        // degenerate cases, and any third asset.
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVenueAdapter
    /// @dev Reverts `UnsupportedAssetPair` rather than returning 0 for a pair
    ///      this venue cannot serve. The asymmetry with {quote} is deliberate:
    ///      a quote is a question and 0 is a valid answer, whereas a swap is an
    ///      instruction, and silently doing nothing while returning 0 would let
    ///      a caller believe a trade settled.
    function swap(OrderTypes.Order calldata order, address recipient) external returns (uint256 amountOut) {
        if (order.assetIn == address(stable) && order.assetOut == address(equityToken)) {
            return _buy(order, recipient);
        }

        if (order.assetIn == address(equityToken) && order.assetOut == address(stable)) {
            return _sell(order, recipient);
        }

        revert UnsupportedAssetPair();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: BUY (MINT)
    //////////////////////////////////////////////////////////////*/

    /// @dev PRIMARY ISSUANCE. Mint shares to `recipient` at par and forward the
    ///      stable to the vault.
    ///
    ///      ============ WHAT IS ASSUMED vs WHAT IS MEASURED ============
    ///      The engine pre-funds this adapter with EXACTLY `order.amountIn` on a
    ///      buy. This adapter consumes exactly that figure and NEVER SWEEPS ITS
    ///      OWN BALANCE, so any pre-existing donation sitting at this address is
    ///      left untouched.
    ///
    ///      THAT IS A STATED CONTRACT ABOUT WHAT THE CALLER GUARANTEES, NOT A
    ///      DELTA THIS ADAPTER MEASURES. There is deliberately no
    ///      balance-before/balance-after computation on this side — unlike the
    ///      sell side, where a conversion has to be inverted. Honouring
    ///      `order.amountIn` verbatim IS the donation resistance: a sweeping
    ///      adapter would consume the donation, fail the engine's STEP 5 check,
    ///      and be permanently bricked by one wei from anyone.
    ///      =============================================================
    function _buy(OrderTypes.Order calldata order, address recipient) private returns (uint256 amountOut) {
        // FLOOR. The share quantity `order.amountIn` of stable buys at par.
        uint256 sharesToMint = equityToken.amountToShares(order.amountIn);
        if (sharesToMint == 0) revert ZeroAmount();

        // `mint` internally calls `registry.allocateShares` and reverts with
        // `InsufficientAvailableShares` if backing is unavailable. NO DUPLICATE
        // CHECK HERE: {quote} estimated this, but `mint` is the authoritative
        // check, and re-checking beforehand would only widen the window in which
        // the estimate and the truth can differ.
        //
        // NOTE — no attestation-freshness check. The registry in this system has
        // no attestation layer: custody attestation and staleness are the OTHER
        // Part B option ("Proof of Collateral"), which this submission does not
        // implement. If one is ever added, its freshness check belongs in {quote}
        // (returning 0) and its enforcement inside `mint`, not here.
        equityToken.mint(recipient, sharesToMint);

        // EXACTLY `order.amountIn`, never `stable.balanceOf(address(this))`.
        // `order.assetIn` is `stable` on this branch by the condition in {swap}.
        stable.safeTransfer(address(vault), order.amountIn);

        emit PrimaryMint(recipient, sharesToMint, order.amountIn);

        // INFORMATIONAL ONLY. The engine measures its own share delta and does
        // not trust this value — see {IVenueAdapter}. Reported honestly anyway,
        // for a direct integrator that has no measurement of its own.
        amountOut = sharesToMint;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL: SELL (REDEEM)
    //////////////////////////////////////////////////////////////*/

    /// @dev PRIMARY REDEMPTION. Burn exactly the shares this settlement funded
    ///      and pay par out of the vault.
    ///
    ///      ============ TWO THINGS NOT TO READ ON THIS PATH ============
    ///      1. `order.amountIn` IS NOT AN UNRESOLVED CLIENT FIGURE. It is the
    ///         engine's `executableAmountIn`, already derived as
    ///         `floor(sharesIn * m / 1e18)`. See the CALL-SITE ASYMMETRY note.
    ///      2. `equityToken.shares(address(this))` IS NOT "WHAT THIS SETTLEMENT
    ///         FUNDED". That total includes any pre-existing donation, and
    ///         settlement-local funds cannot be distinguished from donated ones
    ///         by inspecting a balance. Reading it would launder a donation into
    ///         a redemption and pay the current client for shares someone else
    ///         sent — and would fail the engine's STEP 5 check on the way.
    ///      =============================================================
    ///
    ///      ============ RESERVE SOLVENCY AFTER AN UPWARD REBASE ============
    ///      A KNOWN, CORRECTLY-HANDLED OPERATIONAL CONDITION — NOT A BUG.
    ///
    ///      A mint deposits stable into the vault ONCE, at the multiplier
    ///      prevailing at that moment. Any SUBSEQUENT upward corporate action
    ///      raises the `balanceOf` value of the shares that deposit backs, while
    ///      the vault receives no additional stable — a corporate action moves
    ///      the multiplier and touches nothing else. A large enough rebase can
    ///      therefore make current-par redemption of a given share quantity
    ///      require more stable than the vault holds. THIS CAN OCCUR WITH EVERY
    ///      CONVERSION IN THIS CONTRACT COMPUTED CORRECTLY.
    ///
    ///      The system's only on-chain obligation is TO FAIL SAFELY, and it has
    ///      exactly two behaviours here:
    ///        - {quote} returns 0, reporting primary as unfillable for that sell.
    ///          Router's existing best-execution loop treats 0 as "skip this
    ///          venue", so the client's order TRANSPARENTLY FALLS BACK TO THE AMM
    ///          with no special-casing in Router or the engine.
    ///        - {swap} reverts `InsufficientReserve` if called anyway (a
    ///          venue-pinned order, or reserve that moved after the quote).
    ///
    ///      What it must never do is pay out less than par silently. It does not:
    ///      the check below is against the full `payout`, not a best-effort
    ///      partial.
    ///
    ///      RECAPITALIZATION IS AN OPERATOR RESPONSIBILITY, exposed via
    ///      `PrimaryReserveVault.adminDeposit`. This contract does not automate
    ///      it and does not monitor for it. Automatic recapitalization — e.g.
    ///      sweeping AMM fee revenue into the vault — is a natural production
    ///      extension, deliberately cut for scope here and recorded as such in
    ///      the README.
    ///      ==================================================================
    function _sell(OrderTypes.Order calldata order, address recipient) private returns (uint256 amountOut) {
        // CEILING, and this is the exact inverse of the engine's
        // `executableAmountIn = floor(sharesIn * m / 1e18)` given `m >= 1e18`
        // (guaranteed by the up-only multiplier). It RECOVERS `sharesIn`
        // EXACTLY — this is not an approximation, and it is not a read of this
        // adapter's total share balance.
        uint256 sharesReceived = equityToken.amountToSharesCeil(order.amountIn);
        if (sharesReceived == 0) revert ZeroAmount();

        // FLOOR, NOT `sharesToAmountCeil`.
        //
        // WHY FLOOR: this is an OUTPUT/OUTFLOW context — the vault is paying
        // stable OUT in exchange for burned shares. Every outflow in this system
        // floors, so the protocol never pays out more than a share is exactly
        // worth: the engine's fee capture, the engine's sell-path input debit,
        // and the buy-quote figure in {quote} all floor. Ceiling here would be
        // THE ONE PLACE IN THE SYSTEM WHERE ROUNDING FAVOURS THE RECIPIENT OVER
        // THE PROTOCOL — backwards relative to every other rounding decision
        // made, and a per-redemption leak that anyone could repeat at will.
        //
        // CONTRAST WITH `sharesToAmountCeil`'S ACTUAL CORRECT USE. That helper
        // exists for SIZING AN ALLOWANCE that must permit spending an exact
        // share quantity — A5's `approveShares`, and the engine's
        // allowance-sufficiency check. That is an INPUT-SIDE, PERMISSION-SIZING
        // context, where rounding down would leave the allowance one wei short
        // and revert the very transfer it exists to authorise. Using it for an
        // output payment reuses a helper outside the context its rounding
        // direction was designed for, and the fact that both are "shares to
        // amount" is not a reason to think either would do.
        uint256 payout = equityToken.sharesToAmount(sharesReceived);

        if (vault.reserveBalance() < payout) revert InsufficientReserve();

        // Burns EXACTLY `sharesReceived == sharesIn` from this adapter's share
        // balance, and internally releases the same quantity of registry
        // backing. Any pre-existing donated shares are untouched, because this
        // is an exact quantity rather than "redeem everything held" — so
        // `shares(address(this))` returns to EXACTLY its pre-settlement level.
        //
        // Exact equality is expected here, and the engine's one-wei-share
        // tolerance on the sell leg goes unused: that tolerance exists for an
        // AMM spending in TOKEN terms against a check that reads SHARES, which
        // does not apply to a contract that burns an exact share count.
        equityToken.redeem(sharesReceived);

        vault.withdrawTo(recipient, payout);

        emit PrimaryRedeem(recipient, sharesReceived, payout);

        amountOut = payout;
    }
}
