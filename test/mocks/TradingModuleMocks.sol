// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title UnzeroableToken
/// @notice An ERC-20 that reverts when asked to set an allowance to ZERO, and
///         behaves normally otherwise.
/// @dev Models the real class of token that cannot be de-approved: blocklisting
///      tokens that revert for a flagged holder, tokens with a `require(amount >
///      0)` in `approve`, tokens whose approve path calls a hook that reverts.
///      Exists so {TradingModule.setApprovedEngine}'s all-or-nothing revocation
///      can be tested for the failure mode it was designed around, rather than
///      only for the happy path.
contract UnzeroableToken is ERC20 {
    error CannotZeroApproval();

    constructor() ERC20("Unzeroable", "NOZERO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount == 0) revert CannotZeroApproval();
        return super.approve(spender, amount);
    }
}

/// @title SafeSpy
/// @notice A stand-in for a Safe that RECORDS the `operation` of every module
///         execution before performing it.
/// @dev Why a spy rather than an ABI-shape argument. "No function accepts
///      arbitrary calldata, so a delegatecall is unconstructible" is a sound
///      argument but it is an argument — it reasons about the code rather than
///      observing it, and it would keep passing if someone hardcoded
///      `Operation.DelegateCall` at a call site inside the module. This mock
///      makes the claim OBSERVABLE: point a second {TradingModule} at it, drive
///      every path that reaches the Safe, and read back what the module actually
///      asked for.
///
///      `operation` is declared `uint8` deliberately. Solidity's canonical
///      signature for an enum parameter is `uint8`, so
///      `execTransactionFromModuleReturnData(address,uint256,bytes,uint8)` is the
///      same selector Safe exposes — the module cannot tell it is talking to this
///      contract, and the recorded value is the raw enum ordinal
///      (`Call == 0`, `DelegateCall == 1`).
contract SafeSpy {
    /// @notice Raw `operation` ordinal of every module execution, in order.
    uint8[] public operations;

    /// @notice Set true if the module ever asked for anything but `Call`.
    bool public sawDelegateCall;

    /// @notice Mirrors Safe's module execution, recording before executing.
    /// @dev Performs a real `call` so the module's post-execution state reads —
    ///      the share-cap check in particular — see the same world they would
    ///      against a real Safe. Returns `(success, returnData)` rather than
    ///      bubbling, exactly as Safe does, so the module's `success` handling is
    ///      exercised too.
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        operations.push(operation);
        if (operation != 0) sawDelegateCall = true;

        (success, returnData) = to.call{value: value}(data);
    }

    /// @notice Number of module executions recorded.
    function operationCount() external view returns (uint256) {
        return operations.length;
    }

    /// @notice Call `to` as this contract, so tests can drive the module's
    ///         Safe-gated configuration.
    /// @dev Test-only affordance standing in for a Safe owner transaction. Bubbles
    ///      the revert so `expectRevert` assertions still see the module's error.
    function callAsSafe(address to, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
