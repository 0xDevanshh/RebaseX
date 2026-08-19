// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IShareRegistry
/// @notice Interface for the mock underlying-share registry that backs the 1:1
///         primary mint/redeem path of a rebasing tokenised-equity token.
/// @dev SHARES-ONLY INTERFACE. Every quantity crossing this boundary is
///      denominated in underlying share units. No value passed to, returned
///      from, or stored behind this interface is ever scaled by a rebase
///      multiplier. Callers convert to/from token balances on their own side.
interface IShareRegistry {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The registry's record for a single tokenised-equity token.
    /// @param custodiedShares Underlying share units recorded as held for this
    ///                        token — the ceiling on what may be minted.
    /// @param allocatedShares Share units currently minted against this record.
    ///                        Invariant: allocatedShares <= custodiedShares.
    /// @param registered      Whether this token has been registered by admin.
    struct ShareRecord {
        uint256 custodiedShares;
        uint256 allocatedShares;
        bool registered;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token has no record; admin must register it first.
    error NotRegistered(address token);

    /// @notice Token already has a record.
    error AlreadyRegistered(address token);

    /// @notice Allocation would push allocatedShares above custodiedShares.
    error InsufficientAvailableShares(uint256 requested, uint256 available);

    /// @notice Release would push allocatedShares below zero.
    error InsufficientAllocatedShares(uint256 requested, uint256 allocated);

    /// @notice New custodied figure is below what is already minted against it.
    error CustodiedBelowAllocated(uint256 custodiedShares, uint256 allocatedShares);

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Zero share amount supplied where a non-zero amount is required.
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when admin registers a new tokenised-equity token.
    event TokenRegistered(address indexed token);

    /// @notice Emitted when admin changes the recorded underlying share count.
    /// @param token                 The token whose record changed.
    /// @param previousCustodiedShares Recorded share units before this call.
    /// @param newCustodiedShares      Recorded share units after this call.
    /// @param allocatedShares         Currently minted against the record.
    event CustodiedSharesUpdated(
        address indexed token,
        uint256 previousCustodiedShares,
        uint256 newCustodiedShares,
        uint256 allocatedShares
    );

    /// @notice Emitted when a token reserves share units against its record (mint).
    /// @param token                The token that allocated, always msg.sender.
    /// @param shareAmount          Share units allocated by this call.
    /// @param newAllocatedShares   Total allocated after this call.
    /// @param availableSharesAfter Remaining unallocated headroom after this call.
    event SharesAllocated(
        address indexed token, uint256 shareAmount, uint256 newAllocatedShares, uint256 availableSharesAfter
    );

    /// @notice Emitted when a token releases share units back to its record (redeem).
    /// @param token                The token that released, always msg.sender.
    /// @param shareAmount          Share units released by this call.
    /// @param newAllocatedShares   Total allocated after this call.
    /// @param availableSharesAfter Remaining unallocated headroom after this call.
    event SharesReleased(
        address indexed token, uint256 shareAmount, uint256 newAllocatedShares, uint256 availableSharesAfter
    );

    /*//////////////////////////////////////////////////////////////
                          TOKEN-FACING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve `shareAmount` share units against the caller's own record.
    /// @dev Called by the tokenised-equity token on mint. Self-keyed: the record
    ///      is keyed by msg.sender, so a token can only ever move its own
    ///      allocation. Reverts if the record is oversubscribed.
    /// @param shareAmount Share units to allocate.
    function allocateShares(uint256 shareAmount) external;

    /// @notice Release `shareAmount` share units from the caller's own record.
    /// @dev Called by the tokenised-equity token on redeem. Self-keyed for the
    ///      same reason as {allocateShares}.
    /// @param shareAmount Share units to release.
    function releaseShares(uint256 shareAmount) external;

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a tokenised-equity token so it can allocate share units.
    /// @param token Address of the token contract.
    function registerToken(address token) external;

    /// @notice Set the underlying share units recorded as held for `token`.
    /// @param token               Address of the registered token.
    /// @param newCustodiedShares  Total underlying share units held.
    function setCustodiedShares(address token, uint256 newCustodiedShares) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying share units recorded as held for `token`.
    function custodiedShares(address token) external view returns (uint256);

    /// @notice Share units currently minted against `token`'s record.
    function allocatedShares(address token) external view returns (uint256);

    /// @notice Share units recorded but not yet allocated: custodied - allocated.
    function availableShares(address token) external view returns (uint256);

    /// @notice Whether `token` has been registered.
    function isRegistered(address token) external view returns (bool);
}
