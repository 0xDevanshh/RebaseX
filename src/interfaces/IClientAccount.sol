// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IClientAccount
/// @notice Minimal surface the Router needs from a client smart account.
/// @dev Intentionally one function. The Router only ever needs to answer one
///      question — "may this caller submit orders for this account?" — and giving
///      it a narrower view of the account than the account's full capability set
///      means a Router bug cannot reach anything else.
///
///      The A5 client smart account will implement this. Trading and withdrawal
///      functions are deliberately absent: the operator's trade permission is
///      exercised by submitting orders through the Router, not by the Router
///      calling into the account.
interface IClientAccount {
    /// @notice Whether `operator` may act for this account.
    /// @dev Callers must tolerate this reverting or being absent — an account may
    ///      be an EOA or a contract that does not implement this interface — and
    ///      must treat any such failure as "not authorized" rather than letting a
    ///      low-level decoding error surface.
    /// @param operator Address to check.
    /// @return authorized True if `operator` is an authorized operator.
    function isOperator(address operator) external view returns (bool authorized);
}
