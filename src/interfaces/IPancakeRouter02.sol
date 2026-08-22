// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPancakeRouter02
/// @notice The two PancakeSwap V2 router members {PancakeSwapAdapter} actually calls.
/// @dev DELIBERATELY MINIMAL — two functions out of a router surface that has
///      roughly thirty. This system depends on nothing it does not use, which is
///      the same discipline {IVenueAdapter} itself is written to: an interface
///      names the calls that are made, not the calls that exist.
///
///      WHY NOT IMPORT THE REAL PACKAGE. Pulling in PancakeSwap's own periphery
///      package would add a dependency, a second solc pragma to reconcile (the published
///      interfaces target 0.6.x), and roughly thirty declarations that nothing in
///      this repository calls. A reviewer auditing this adapter's venue surface
///      would then have to establish which of those thirty are reachable. Here
///      that question answers itself: the venue surface is this file, and it is
///      two functions long.
///
///      SAFETY OF A HAND-DECLARED INTERFACE. An interface is a calldata encoding,
///      not a proof the target implements it. Both selectors below are taken from
///      the deployed V2 router ABI and must match exactly, since a wrong selector
///      would compile cleanly and fail at runtime. {PancakeSwapAdapter}'s
///      constructor checks the router address holds code; the fork test is what
///      confirms these calls actually land on a real deployment.
interface IPancakeRouter02 {
    /// @notice Output amounts along `path` for an input of `amountIn`.
    /// @dev REVERTS rather than returning zero when the path has no pair, when a
    ///      pair holds zero reserves, or when `amountIn` is zero. That is why
    ///      {PancakeSwapAdapter.quote} wraps this call in try/catch — the venue
    ///      contract for a quote in this system is "return 0 when unfillable",
    ///      and this function does not honour it.
    ///
    ///      This is a view over CURRENT reserves. It is indicative only; nothing
    ///      about it is a commitment to execute at the returned figure.
    /// @param amountIn Input amount of `path[0]`.
    /// @param path     Swap path. This adapter only ever passes a direct
    ///                 two-token path.
    /// @return amounts Amount at each hop; `amounts[0] == amountIn` and the last
    ///                 element is the output.
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    /// @notice Swap exactly `amountIn` of `path[0]` for `path[path.length - 1]`,
    ///         pricing the trade off the input the pair MEASURES rather than the
    ///         input the caller states.
    /// @dev RETURNS NOTHING. That is a property of this variant, not an omission
    ///      in this declaration: the amount delivered is not knowable to the
    ///      router until after the pair has measured its own balance change, and
    ///      the function does not report it back. Measuring the recipient's
    ///      balance delta is therefore the ONLY way to learn the output — see
    ///      {PancakeSwapAdapter.swap}.
    ///
    ///      Pulls `amountIn` from the caller via `transferFrom`, so the caller
    ///      must have approved the router for at least that amount first.
    /// @param amountIn     Input amount, pulled from `msg.sender`.
    /// @param amountOutMin Minimum acceptable output, enforced by the router.
    ///                     {PancakeSwapAdapter} passes 0 on purpose — see its
    ///                     {PancakeSwapAdapter.swap} NatSpec.
    /// @param path         Swap path.
    /// @param to           Recipient of the output. Receives it DIRECTLY from the
    ///                     final pair; the caller never custodies it.
    /// @param deadline     Unix timestamp after which the router rejects the swap.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
