// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPancakeRouter02} from "../interfaces/IPancakeRouter02.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title PancakeSwapAdapter
/// @notice PancakeSwap V2 as an ordinary execution venue behind {IVenueAdapter}.
/// @dev ============ WHAT THIS CONTRACT IS AND IS NOT ============
///      It is a translation layer, and nothing else. It converts this system's
///      {OrderTypes.Order} into a PancakeSwap V2 router call and reports what
///      arrived. It holds no funds between settlements, has no roles, no admin,
///      no configuration, and no state beyond one immutable address.
///
///      Everything that could be called policy lives elsewhere ON PURPOSE:
///        - slippage      -> {SettlementEngine} STEP 7, on the FINAL NET output
///        - venue choice  -> `Router._resolveVenue`, via the {quote} below
///        - share accounting -> {SettlementEngine}, which measures its own deltas
///      This adapter contributes no second opinion on any of the three. See the
///      per-function notes for why each of those is a correctness requirement
///      rather than a division of labour chosen for tidiness.
///      ===========================================================
///
///      ============ WHY THE FEE-ON-TRANSFER SWAP VARIANT ============
///      READ THIS BEFORE CONCLUDING THE EQUITY TOKEN CHARGES A TRANSFER FEE. IT
///      DOES NOT. The variant is named for the token class it was introduced to
///      serve, not for the only condition under which it is the correct call.
///
///      PancakeSwap V2's PLAIN `swapExactTokensForTokens` prices the output from
///      the CALLER-STATED `amountIn`, transfers that stated amount into the pair,
///      and then the pair re-derives the input it actually received as
///      `balanceOf(pair) - reserveInput` and asserts the constant-product
///      invariant against it. Those two figures must agree exactly. If the pair's
///      measured balance change is even one unit short of the stated amount, the
///      output was priced for input the pair never received, the invariant check
///      fails, and the call reverts `Pancake: K`.
///
///      This system has a token whose transfers are NOT GUARANTEED to move a
///      caller-stated nominal amount 1:1. {MockRebasingEquityToken} holds
///      balances as SHARES and derives `balanceOf` as `floor(shares * m / 1e18)`,
///      so a token-denominated transfer is converted to shares and back, and the
///      floor at each conversion means the recipient's balance can move by
///      slightly less than the nominal figure at an awkward multiplier. Whether
///      any given transfer is short depends on the multiplier and the amount —
///      which is exactly what makes the plain variant fail NON-DETERMINISTICALLY
///      here, passing in testing and reverting in production on the same code
///      path with different numbers.
///
///      `swapExactTokensForTokensSupportingFeeOnTransferTokens` closes this by
///      construction: it never prices from the stated amount at all. The pair
///      measures its own balance delta and computes the output from THAT, so a
///      short transfer produces a proportionally smaller output instead of a
///      failed invariant. The rounding gap becomes a price outcome — which
///      {SettlementEngine}'s `minAmountOut` already bounds — rather than a revert.
///
///      So the choice here is ROUNDING-SAFETY, not fee accommodation. The two
///      happen to need the same router function.
///      =============================================================
///
///      ============ SCOPE: SINGLE-HOP ONLY — A STATED LIMITATION ============
///      This adapter supports ONLY a direct two-token path `[assetIn, assetOut]`.
///      It does not hop through WBNB, does not consult a factory, and contains no
///      path-finding of any kind. A pair that does not exist directly is simply a
///      venue that quotes 0 and is skipped.
///
///      Sufficient here because the assessment's scope is one AMM venue trading
///      one pair, and that pair is one this system creates and seeds itself: the
///      tokenised equity is a mock with no organic liquidity anywhere, so there is
///      no multi-hop route to discover even in principle.
///
///      A PRODUCTION VERSION WOULD NEED MORE, and it is worth being precise about
///      what: either a caller-supplied path carried on the order (which widens
///      {OrderTypes.Order} and hands path selection to whoever builds the order),
///      or an on-chain path resolver, or an off-chain router quoting hops and
///      passing them in. Each is a real design decision with its own trust
///      implications, and picking one is out of scope for this submission rather
///      than something this contract should decide by default.
///      ======================================================================
///
///      ============ THE REBASING LEG NEEDS NO SPECIAL HANDLING HERE ==========
///      Both assets are treated as opaque standard ERC-20s throughout. This
///      contract never calls `approveShares`, `transferSharesFrom`, `shares`, or
///      `multiplier`, and never reasons in share units.
///
///      That is not an oversight; it is the only thing an AMM adapter can
///      honestly do. PancakeSwap has no concept of this token's internal share
///      accounting — a V2 pair knows `balanceOf` and `transfer` and nothing else.
///      An adapter that reasoned in shares would be inventing an interpretation
///      the venue does not share.
///
///      All share-level correctness on either side of this swap belongs to
///      {SettlementEngine}, which measures its own SHARE delta on a buy and its
///      own BALANCE delta on a sell (A4's measured-not-reported principle). This
///      adapter's entire job is: move exactly `order.amountIn` of standard ERC-20
///      balance through the pair, and report what arrived.
///      ======================================================================
contract PancakeSwapAdapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The constructor's router argument was zero or held no code.
    /// @dev THE ONLY ERROR THIS CONTRACT DECLARES, and it can only fire at
    ///      deployment. Nothing on the {swap} path is wrapped or re-reported:
    ///      a failed approval, a failed swap, or a router revert propagates
    ///      verbatim and takes the whole settlement down with it, per A4's
    ///      "full revert on any failed leg". Catching and restating them here
    ///      would replace the venue's own diagnostic with a worse one.
    error InvalidPancakeRouter();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The PancakeSwap V2 router this adapter executes against.
    /// @dev IMMUTABLE, so the venue behind a registered `venueId` cannot be
    ///      repointed after review. Changing venues is a deploy-and-register
    ///      operation through {VenueRegistry}, which leaves an on-chain record
    ///      via `AdapterSet`; a mutable pointer here would let the same
    ///      registration silently mean something different later.
    address public immutable pancakeRouter;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param pancakeRouter_ PancakeSwap V2 router address for the target chain.
    /// @dev The `code.length` check is the one that matters. A zero or EOA
    ///      address would deploy cleanly, then make every {quote} return 0 — a
    ///      call to a codeless address succeeds and returns empty data, which the
    ///      try/catch below cannot distinguish from "no pair exists". The venue
    ///      would lose every best-execution comparison silently, forever, with no
    ///      error anywhere to explain it. Failing at deployment is the only cheap
    ///      place to catch that.
    ///
    ///      What this does NOT check is that the address is really a PancakeSwap
    ///      router. No constructor can: a contract with the right selectors and
    ///      wrong behaviour passes any test that fits in a constructor. That is a
    ///      review-and-registration question, and {VenueRegistry} is where the
    ///      decision to trust an adapter is recorded.
    constructor(address pancakeRouter_) {
        if (pancakeRouter_ == address(0) || pancakeRouter_.code.length == 0) revert InvalidPancakeRouter();

        pancakeRouter = pancakeRouter_;
    }

    /*//////////////////////////////////////////////////////////////
                                  QUOTE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVenueAdapter
    /// @dev NEVER REVERTS. Every unfillable case returns 0.
    ///
    ///      ============ THE try/catch IS LOAD-BEARING ============
    ///      `getAmountsOut` REVERTS on the ordinary "this venue cannot serve this
    ///      pair" case — no pair deployed for the path, or a pair whose reserves
    ///      cannot support the computation. Those are not exceptional conditions
    ///      for a registry that may hold venues covering different pairs; they are
    ///      the normal answer for most venue/pair combinations.
    ///
    ///      `Router._resolveVenue` scans EVERY registered venue and treats a 0
    ///      quote as "skip this one". It does catch a reverting quote, so an
    ///      uncaught revert here would not break best execution — but it would
    ///      make this venue's ordinary "not my pair" answer indistinguishable, in
    ///      the Router's catch, from a genuinely broken adapter. Returning 0 says
    ///      the same thing more cheaply and more honestly, and it is what
    ///      {PrimaryVenueAdapter.quote} does for the identical situation. One
    ///      convention, both venues.
    ///      =======================================================
    ///
    ///      ============ INDICATIVE ONLY — AND ONE SPECIFIC REASON WHY ==========
    ///      This reads pool reserves at call time, and reserves move. That much is
    ///      true of any AMM quote and is already stated on {IVenueAdapter.quote}.
    ///
    ///      There is a second, sharper reason specific to this system, and it is
    ///      NOT SOMETHING THIS FUNCTION CAN CORRECT FOR. When one leg is the
    ///      rebasing equity, a corporate action landing between this quote and the
    ///      eventual swap changes the token's `balanceOf` for every holder — the
    ///      pair included — WITHOUT changing the pair's stored `reserve0`/
    ///      `reserve1`. A V2 pair caches reserves and only refreshes them on
    ///      `sync()`, `mint`, `burn`, or `swap`. Until something pokes it, the
    ///      pair prices against reserves that no longer describe what it holds,
    ///      and this quote inherits that staleness.
    ///
    ///      This is the disclosed system-level limitation of putting a rebasing
    ///      token in a constant-product pool that assumes fixed balances. It is
    ///      not a bug in this adapter and this adapter does not attempt to solve
    ///      it — reading reserves and second-guessing them against the token's
    ///      current multiplier would be this contract inventing a price the venue
    ///      would not honour. The protection against acting on a stale quote is
    ///      what it already is everywhere else in this system: `minAmountOut` and
    ///      `deadline`, enforced at settlement. Never trust in a quote.
    ///      =====================================================================
    function quote(address assetIn, address assetOut, uint256 amountIn) external view returns (uint256 amountOut) {
        // Checked before the external call, not because the router would accept
        // them, but because 0 is the answer either way and this states so without
        // a call. `assetIn == assetOut` has no pair by construction.
        if (amountIn == 0 || assetIn == assetOut) return 0;

        address[] memory path = new address[](2);
        path[0] = assetIn;
        path[1] = assetOut;

        try IPancakeRouter02(pancakeRouter).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            // Last hop is the output. Indexed from the end rather than hardcoded
            // to `amounts[1]` so this line stays correct on its own terms; the
            // single-hop restriction is enforced by the path built above, and
            // should not also be assumed silently here.
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVenueAdapter
    /// @dev ============ EXACTLY `order.amountIn`, NEVER A SWEEP ============
    ///      {SettlementEngine} has already pre-funded this adapter with exactly
    ///      `order.amountIn` of `order.assetIn` before this call, per the
    ///      pre-fund convention this shares with {PrimaryVenueAdapter}.
    ///
    ///      This function consumes exactly that figure and never reads its own
    ///      `balanceOf`. The approval below authorises `order.amountIn` and the
    ///      router's internal `transferFrom` moves precisely that — so a
    ///      pre-existing donation sitting at this address is untouchable through
    ///      this path, no matter how large.
    ///
    ///      THAT IS WHAT MAKES THIS ADAPTER DONATION-RESISTANT. The engine's
    ///      STEP 5 post-condition asserts the adapter's input holding returned to
    ///      its PRE-SETTLEMENT level, not to zero. An adapter that swapped its
    ///      whole balance would consume the donation, fail that assertion, and be
    ///      permanently bricked by one wei sent by anyone, at no cost to the
    ///      sender. See {IVenueAdapter} — this is a stated hard requirement of the
    ///      interface, not a local precaution.
    ///      ====================================================================
    ///
    ///      ============ WHY `amountOutMin` IS 0, AND WHY THAT IS CORRECT ========
    ///      NOT A MISSING SLIPPAGE CHECK. Slippage policy exists in exactly one
    ///      place in this system: {SettlementEngine}'s STEP 7 check of
    ///      `order.minAmountOut` against the FINAL NET output, after the execution
    ///      fee is taken. {IVenueAdapter} states the division explicitly —
    ///      "Enforcing `order.minAmountOut` is the caller's responsibility, so
    ///      slippage policy stays in one place."
    ///
    ///      Passing `order.minAmountOut` through to the router would create a
    ///      SECOND floor that is quietly the wrong one: the router would check it
    ///      against the GROSS output, while the engine checks the same number
    ///      against the NET. Trades landing between the two would revert at the
    ///      venue for a bound the client's actual protection would have passed,
    ///      and the failure would surface as an opaque router revert rather than
    ///      as the engine's named slippage error. Two checks, two different
    ///      quantities, one of them invisible. Zero here is the implementation of
    ///      the stated contract, not an omission from it.
    ///      ====================================================================
    ///
    ///      ============ THE OUTPUT IS MEASURED AT `recipient` ============
    ///      `swapExactTokensForTokensSupportingFeeOnTransferTokens` RETURNS
    ///      NOTHING — there is no reported figure available to trust, so measuring
    ///      is the only way to learn the output, not a choice made over a cheaper
    ///      alternative.
    ///
    ///      It is measured at `recipient` rather than here because the variant
    ///      delivers output DIRECTLY from the final pair to the `to` address. This
    ///      adapter never custodies `assetOut` at any point: there is nothing to
    ///      forward afterwards, and the engine's adapter-retention post-condition
    ///      has nothing to catch on the output leg (it guards the INPUT leg, which
    ///      is where this adapter does briefly hold funds).
    ///
    ///      The returned value is INFORMATIONAL ONLY. {SettlementEngine} passes
    ///      `address(this)` as `recipient` and independently measures its own
    ///      share delta on a buy or balance delta on a sell; it does not read this
    ///      return value for accounting. It is reported honestly regardless, for a
    ///      direct integrator that has no measurement of its own.
    ///      ===============================================================
    ///
    ///      NO try/catch ANYWHERE ON THIS PATH. A failed approval or a reverting
    ///      swap must take the entire settlement down, so no partially settled
    ///      state can persist. The try/catch in {quote} exists because a quote
    ///      must degrade gracefully; a swap is an instruction, and an instruction
    ///      that cannot be carried out must fail loudly.
    function swap(OrderTypes.Order calldata order, address recipient) external returns (uint256 amountOut) {
        // `forceApprove` rather than `approve`: it zeroes first where a token
        // requires it, which keeps this correct against the non-standard
        // allowance behaviour common among tokens a public AMM can be pointed at.
        IERC20(order.assetIn).forceApprove(pancakeRouter, order.amountIn);

        address[] memory path = new address[](2);
        path[0] = order.assetIn;
        path[1] = order.assetOut;

        uint256 recipientBefore = IERC20(order.assetOut).balanceOf(recipient);

        IPancakeRouter02(pancakeRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                order.amountIn,
                0, // amountOutMin — see the slippage note above
                path,
                recipient,
                order.deadline
            );

        uint256 recipientAfter = IERC20(order.assetOut).balanceOf(recipient);
        amountOut = recipientAfter - recipientBefore;

        // Leave no standing allowance to a contract this adapter does not
        // otherwise trust. The router should have consumed the whole approval via
        // its internal `transferFrom`, so this normally writes an already-zero
        // slot — but "should have" is an assumption about someone else's code,
        // and this is one cheap call to stop depending on it.
        IERC20(order.assetIn).forceApprove(pancakeRouter, 0);
    }
}
