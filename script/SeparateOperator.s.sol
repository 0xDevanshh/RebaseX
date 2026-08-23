// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {Enum} from "safe-contracts/common/Enum.sol";
import {Safe} from "safe-contracts/Safe.sol";

import {TradingModule} from "../src/accounts/TradingModule.sol";

/// @title SeparateOperator
/// @notice Closes the audit finding that the live testnet deployment's
///         admin/operator/feeRecipient key was ALSO the Safe's sole owner,
///         which made the "operator cannot withdraw" non-custodial claim
///         architecturally true but never actually EXERCISED by this
///         deployment — there was no second key anywhere to make
///         "operator != owner" a real distinction.
/// @dev Grants {TradingModule} operator status to a genuinely separate key
///      (`NEW_OPERATOR`, read from env) and revokes it from the admin/owner
///      key. Both are `onlySafe` writes, so both go through the same
///      pre-validated-signature Safe transaction mechanism
///      {Deploy.s.sol} already uses and documents in full — see that file's
///      contract-level NatSpec for why the `v == 1` "approved hash" form is
///      valid on a real broadcast, not merely inside a test VM. Not
///      re-derived here to avoid two copies of the same argument drifting
///      apart.
///
///      DELIBERATELY SCOPED to operator/owner separation only. The admin's
///      other roles (DEFAULT_ADMIN_ROLE on the registries/engine,
///      PRIMARY_ROLE, CORPORATE_ACTION_ROLE, fee recipient) are legitimate
///      protocol-admin powers, not Safe-custody powers, and redistributing
///      those was not the finding this script closes — doing so
///      unprompted would be scope creep the audit did not ask for.
///
///      Revoking the admin's own operator flag does not reduce the admin's
///      capabilities: as the Safe's owner, `onlyOperatorOrSafe`'s
///      `msg.sender == safe` branch already lets it call every operator
///      action directly through an owner transaction. The flag was
///      redundant with owner status, not an independent grant — removing
///      it only removes the appearance that operator and owner are the
///      same role, which they no longer are once `NEW_OPERATOR` exists.
contract SeparateOperator is Script {
    function run() external {
        string memory json = vm.readFile("deployments/bsc-testnet.json");

        address admin = vm.parseJsonAddress(json, ".admin");
        address safe = vm.parseJsonAddress(json, ".safe");
        address module = vm.parseJsonAddress(json, ".tradingModule");

        address newOperator = vm.envAddress("NEW_OPERATOR");
        require(newOperator != address(0), "SeparateOperator: NEW_OPERATOR not set");
        require(newOperator != admin, "SeparateOperator: NEW_OPERATOR must differ from admin/owner");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(deployerKey) == admin, "SeparateOperator: PRIVATE_KEY does not match recorded admin");

        console2.log("Safe:            ", safe);
        console2.log("TradingModule:   ", module);
        console2.log("Admin (owner):   ", admin);
        console2.log("New operator:    ", newOperator);
        console2.log("Operator before -> admin:", TradingModule(module).isOperator(admin));
        console2.log("Operator before -> new:  ", TradingModule(module).isOperator(newOperator));

        vm.startBroadcast(deployerKey);

        _execAsOwner(safe, module, abi.encodeCall(TradingModule.setOperator, (newOperator, true)), admin);
        _execAsOwner(safe, module, abi.encodeCall(TradingModule.setOperator, (admin, false)), admin);

        vm.stopBroadcast();

        bool adminIsOperator = TradingModule(module).isOperator(admin);
        bool newIsOperator = TradingModule(module).isOperator(newOperator);

        console2.log("Operator after  -> admin:", adminIsOperator);
        console2.log("Operator after  -> new:  ", newIsOperator);

        require(!adminIsOperator, "SeparateOperator: admin still flagged as operator");
        require(newIsOperator, "SeparateOperator: new operator was not granted");

        console2.log("Confirmed: operator and Safe owner are now distinct keys.");
    }

    /// @dev Identical mechanism to {Deploy.s.sol._execAsOwner} — see that
    ///      file for the full argument. Not imported from there because
    ///      that helper is `private` on a different script contract; the
    ///      encoding itself is a few lines of pure byte layout, not logic
    ///      worth sharing behind an interface for one more call site.
    function _execAsOwner(address safe, address to, bytes memory data, address owner) private {
        bytes memory signature = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));

        (bool ok, bytes memory ret) = safe.call(
            abi.encodeCall(
                Safe.execTransaction,
                (to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signature)
            )
        );

        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
