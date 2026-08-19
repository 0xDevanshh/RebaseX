// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OrderTypes
/// @notice Shared trade-request type used by the Router and every venue adapter.
/// @dev Struct-only library, so it compiles to no bytecode and costs nothing to
///      depend on. It exists so the Router and adapters agree on one definition
///      of "an order" rather than each declaring their own.
library OrderTypes {
    /// @notice One trade request.
    /// @param account      Client account whose trade is being executed, and the
    ///                     party the input is drawn from.
    /// @param assetIn      Token being sold.
    /// @param assetOut     Token being received.
    /// @param amountIn     Input amount of `assetIn`.
    /// @param minAmountOut Minimum acceptable output. Slippage protection: the
    ///                     trade must revert rather than settle below this.
    /// @param venueId      Identifier resolved through the VenueRegistry to an
    ///                     adapter address.
    /// @param deadline     Unix timestamp after which the order must not execute.
    struct Order {
        address account;
        address assetIn;
        address assetOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes32 venueId;
        uint256 deadline;
    }
}
