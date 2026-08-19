// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title ISettlementEngine
/// @notice Executes a routed order: moves funds, calls the venue adapter,
///         enforces slippage, and captures the execution fee.
/// @dev DIVISION OF RESPONSIBILITY. The Router orchestrates and holds nothing;
///      the settlement engine is where every movement of value happens. Slippage
///      is enforced HERE and only here, against realised execution results — the
///      Router deliberately does not re-check `minAmountOut`, because one rule
///      implemented in two places is a rule that will eventually disagree with
///      itself.
interface ISettlementEngine {
    /// @notice Settle `order` on `adapter`, the adapter registered for
    ///         `resolvedVenueId`.
    /// @dev THE ROUTER IS NOT A TRUST ANCHOR. An implementation MUST independently
    ///      verify that `venueRegistry.getAdapter(resolvedVenueId) == adapter`
    ///      rather than accepting the pair on the caller's word. Two reasons:
    ///
    ///        - `settle` is an external function. Nothing stops a caller other
    ///          than the Router from invoking it with an arbitrary adapter
    ///          address, so the pairing has to be checked where the funds move.
    ///        - Even with a trusted Router, re-deriving the adapter from the
    ///          registry means a single source of truth for "which contract
    ///          executes this venue", instead of two that could drift.
    ///
    ///      An implementation MUST also enforce `order.minAmountOut` against the
    ///      amount actually realised, and MUST revert the whole call on any failed
    ///      leg so no partially settled state can persist.
    ///
    ///      `resolvedVenueId` is passed separately from `order.venueId` because
    ///      they differ for best execution:
    ///        - explicit order:        `order.venueId == resolvedVenueId`
    ///        - best-execution order:  `order.venueId == bytes32(0)` while
    ///                                 `resolvedVenueId` is the chosen venue.
    ///      Without it, settlement could not tell which venue was selected, and
    ///      so could not validate the adapter at all.
    /// @param order           The original, unmodified order.
    /// @param resolvedVenueId Concrete venue selected for execution, never zero.
    /// @param adapter         Adapter the caller resolved for `resolvedVenueId`.
    /// @return amountOut Amount of `order.assetOut` delivered to the client.
    function settle(OrderTypes.Order calldata order, bytes32 resolvedVenueId, address adapter)
        external
        returns (uint256 amountOut);
}
