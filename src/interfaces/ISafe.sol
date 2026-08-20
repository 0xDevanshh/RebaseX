// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISafe
/// @notice The slice of a Safe (v1.4.1) that a module needs.
/// @dev WHY A LOCAL INTERFACE RATHER THAN AN IMPORT. Safe v1.4.1 ships no
///      `ISafe`/`IModuleManager`; the module-facing surface is the abstract
///      `ModuleManager` contract. Importing that to obtain a call type would pull
///      Safe's whole inheritance tree — and its LGPL-3.0-only source — into the
///      compilation of `src/`, to get a function selector. Declaring the two
///      functions used keeps `src/` free of Safe source while remaining
///      ABI-identical, and keeps the module's dependency on Safe visible as
///      exactly two calls rather than as an inherited hierarchy.
///
///      `Operation` is redeclared rather than imported for the same reason. Solidity
///      encodes an enum as `uint8`, so this is ABI-compatible with Safe's
///      `Enum.Operation` by construction: `Call == 0`, `DelegateCall == 1`. The
///      ORDER OF THESE MEMBERS IS LOAD-BEARING — swapping them would silently turn
///      every `Operation.Call` in a module into a delegatecall executing in the
///      Safe's own context, which can rewrite the Safe's owners. It matches
///      `safe-contracts/common/Enum.sol`.
interface ISafe {
    /// @notice Safe's call type. `Call` executes in the target's context;
    ///         `DelegateCall` executes the target's code in the SAFE's context.
    enum Operation {
        Call,
        DelegateCall
    }

    /// @notice Execute a transaction from an enabled module and return its result.
    /// @dev Reverts (GS104) unless `msg.sender` is an enabled module of this Safe.
    ///
    ///      RETURNS A BOOL RATHER THAN BUBBLING. A failed inner call yields
    ///      `success == false` and an `ExecutionFromModuleFailure` event; it does
    ///      NOT revert the module's transaction. Every caller must check `success`
    ///      or it will silently treat a failed execution as a completed one.
    /// @param to        Call target.
    /// @param value     Native value to send.
    /// @param data      Calldata for `to`.
    /// @param operation Call or DelegateCall.
    /// @return success    Whether the inner call succeeded.
    /// @return returnData Raw return data of the inner call.
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, Operation operation)
        external
        returns (bool success, bytes memory returnData);

    /// @notice Whether `module` is currently enabled on this Safe.
    /// @dev Read-only; a module cannot enable itself.
    function isModuleEnabled(address module) external view returns (bool);
}
