// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title IVenueAdapter
/// @notice Common API every execution venue implements.
/// @dev WHY THIS EXISTS. The Router resolves a `venueId` to an adapter and calls
///      it through this interface only. It therefore contains no PancakeSwap
///      types, addresses, path arrays, or fee constants — venue-specific detail
///      lives entirely behind an implementation of this interface.
///
///          Router --venueId--> VenueRegistry --address--> IVenueAdapter
///                                                              |
///                                                   PancakeSwapAdapter
///                                                   (future adapters)
///
///      Adding a venue is therefore a deploy-and-register operation, not a Router
///      change.
interface IVenueAdapter {
    /// @notice Expected output for selling `amountIn` of `assetIn` for `assetOut`.
    /// @dev A view quote for routing decisions. It is indicative only: it reflects
    ///      venue state at call time, which can move before execution. Slippage
    ///      protection comes from `Order.minAmountOut` at settlement, never from
    ///      trusting this figure.
    /// @param assetIn  Token being sold.
    /// @param assetOut Token being received.
    /// @param amountIn Input amount.
    /// @return amountOut Expected output amount.
    function quote(address assetIn, address assetOut, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Execute `order` on this venue and deliver the output to `recipient`.
    /// @dev SETTLEMENT CONVENTION. The caller must ensure the adapter already
    ///      holds `order.amountIn` of `order.assetIn` before calling. The adapter
    ///      does not pull funds itself.
    ///
    ///      Chosen because the adapter must measure its own realised balances to
    ///      support the rebasing equity token — a transferred amount is not
    ///      reliably equal to the balance delta it produces, so the adapter needs
    ///      the funds in hand to measure what it actually received before pricing
    ///      the venue call.
    ///
    ///      ============ `order.amountIn` IS AUTHORITATIVE ============
    ///      An implementation MUST execute EXACTLY `order.amountIn` of
    ///      `order.assetIn` from its pre-funded balance, and MUST NOT touch any
    ///      pre-existing holding. It must not swap its whole `assetIn` balance,
    ///      and must not treat `order.amountIn` as a hint, a maximum, or an
    ///      indicative figure to be re-derived from what it happens to hold.
    ///
    ///      WHY THIS IS A HARD REQUIREMENT: an adapter that sweeps its entire
    ///      balance consumes anything already sitting at its address — residue
    ///      from a prior settlement, or an unsolicited donation from anyone at
    ///      all. The settlement engine asserts after every swap that the
    ///      adapter's input holding returned to its pre-settlement level, so a
    ///      sweeping adapter fails that assertion on every subsequent settlement.
    ///      ONE WEI SENT TO SUCH AN ADAPTER BRICKS IT PERMANENTLY, at no cost to
    ///      the sender and with no way to recover. Executing only the funded
    ///      amount is what makes the adapter donation-resistant.
    ///
    ///      NOTE FOR CALLERS: the engine may pass an order whose `amountIn`
    ///      differs from the client's original request — on a sell of a rebasing
    ///      token the requested amount is resolved to a whole number of shares
    ///      first, and the executable amount is derived back from those shares.
    ///      The struct this function receives always carries the quantity that
    ///      was actually funded, so honouring `order.amountIn` is always correct.
    ///      ===========================================================
    ///
    ///      An adapter must not retain client funds: everything it receives is
    ///      either spent on the venue or forwarded to `recipient`.
    ///
    ///      `amountOut` is the amount actually delivered, measured rather than
    ///      assumed. Enforcing `order.minAmountOut` is the caller's
    ///      responsibility, so slippage policy stays in one place. The caller does
    ///      NOT rely on this return value for accounting — it measures its own
    ///      balance and share deltas instead — but an implementation must still
    ///      report it honestly, since it is what a direct integrator would read.
    /// @param order     The trade request.
    /// @param recipient Address to receive `order.assetOut`.
    /// @return amountOut Output amount actually delivered to `recipient`.
    function swap(OrderTypes.Order calldata order, address recipient) external returns (uint256 amountOut);
}
