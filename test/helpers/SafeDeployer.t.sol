// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Safe} from "safe-contracts/Safe.sol";
import {ModuleManager} from "safe-contracts/base/ModuleManager.sol";
import {Enum} from "safe-contracts/common/Enum.sol";

import {MockStable} from "../../src/mocks/MockStable.sol";
import {SafeDeployer} from "./SafeDeployer.sol";

/// @notice Smallest possible stand-in for `TradingModule`: it does nothing but
///         relay one call through the Safe's module path.
/// @dev Deliberately unrestricted. Its job is to prove that the *Safe's* module
///      mechanism is what gates it — not that the module has good access control
///      of its own. Two instances are used in these tests: one enabled, one not.
contract DummyModule {
    /// @notice Move `amount` of `token` out of `safe` to `to` as a module.
    function pullToken(address safe, address token, address to, uint256 amount) external returns (bool success) {
        return ModuleManager(safe)
            .execTransactionFromModule(token, 0, abi.encodeCall(IERC20.transfer, (to, amount)), Enum.Operation.Call);
    }
}

/// @title SafeDeployerTest
/// @notice Verifies the Safe test harness before any RebaseX contract is written
///         against it.
/// @dev These assertions are load-bearing for A5's non-custody claim. The claim
///      is not "the module has no withdraw function" — it is "the Safe holds the
///      assets, and the only authority the module has is the authority the Safe
///      granted it." That is only true if the Safe's module mechanism is real and
///      exclusive, which is what the last two tests establish:
///
///        - an enabled module can move Safe assets  (authority exists)
///        - a non-enabled address cannot            (authority is exclusive)
///
///      If either failed, every later argument about custody would be decoration.
contract SafeDeployerTest is Test, SafeDeployer {
    address internal constant OWNER = address(0xA11CE);
    address internal constant NOT_OWNER = address(0xBAD);
    address internal constant RECIPIENT = address(0xF00D);

    uint256 internal constant FUNDING = 1_000e18;

    address internal safe;
    DummyModule internal module;
    DummyModule internal rogueModule;
    MockStable internal token;

    function setUp() public {
        address[] memory owners = new address[](1);
        owners[0] = OWNER;
        safe = deploySafe(owners, 1);

        module = new DummyModule();
        rogueModule = new DummyModule();

        token = new MockStable("Mock USD", "mUSD", 18);
        token.mint(safe, FUNDING);

        vm.label(OWNER, "owner");
        vm.label(NOT_OWNER, "notOwner");
        vm.label(address(module), "enabledModule");
        vm.label(address(rogueModule), "rogueModule");
    }

    /*//////////////////////////////////////////////////////////////
                        1. SAFE DEPLOYS AS ASKED
    //////////////////////////////////////////////////////////////*/

    function test_DeploysWithExpectedOwnerAndThreshold() public view {
        address[] memory owners = Safe(payable(safe)).getOwners();

        assertEq(owners.length, 1, "owner count");
        assertEq(owners[0], OWNER, "owner");
        assertEq(Safe(payable(safe)).getThreshold(), 1, "threshold");
        assertTrue(Safe(payable(safe)).isOwner(OWNER), "isOwner(owner)");
        assertFalse(Safe(payable(safe)).isOwner(NOT_OWNER), "isOwner(notOwner)");

        // A freshly set-up Safe has no modules — the module list is only the sentinel.
        assertEq(safeModules(safe).length, 0, "no modules at setup");
    }

    function test_DeploySafeGivesDistinctAddresses() public {
        // Two Safes with an identical owner set must not collide on the factory's
        // CREATE2 salt, or a test needing two client accounts silently gets one.
        address[] memory owners = new address[](1);
        owners[0] = OWNER;
        assertTrue(deploySafe(owners, 1) != deploySafe(owners, 1), "distinct proxies");
    }

    /*//////////////////////////////////////////////////////////////
                    2. A MODULE CAN BE ENABLED, FOR REAL
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanEnableModule() public {
        assertFalse(Safe(payable(safe)).isModuleEnabled(address(module)), "not enabled yet");

        vm.expectEmit(true, false, false, false, safe);
        emit ModuleManager.EnabledModule(address(module));
        enableModule(safe, address(module), OWNER);

        assertTrue(Safe(payable(safe)).isModuleEnabled(address(module)), "isModuleEnabled");

        address[] memory modules = safeModules(safe);
        assertEq(modules.length, 1, "module count");
        assertEq(modules[0], address(module), "module in list");
    }

    /*//////////////////////////////////////////////////////////////
                    3. NOBODY ELSE CAN ENABLE A MODULE
    //////////////////////////////////////////////////////////////*/

    /// @dev A non-owner's pre-validated signature clears the `msg.sender ==
    ///      currentOwner` check (GS025) — it genuinely is that address — and then
    ///      dies on the owner-set membership check (GS026). Confirming GS026
    ///      specifically matters: it shows the pre-validated form is not a way
    ///      around ownership, only around key custody in the test harness.
    function test_NonOwnerCannotEnableModule() public {
        bytes memory data = abi.encodeCall(ModuleManager.enableModule, (address(module)));
        bytes memory signature = _prevalidatedSignature(NOT_OWNER);

        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("GS026"));
        Safe(payable(safe))
            .execTransaction(safe, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signature);

        assertFalse(Safe(payable(safe)).isModuleEnabled(address(module)), "still not enabled");
    }

    /// @dev A non-owner cannot forge an owner's pre-validated signature either:
    ///      `r` names OWNER but `msg.sender` is not OWNER, so GS025 fires.
    function test_NonOwnerCannotForgeOwnerSignature() public {
        bytes memory data = abi.encodeCall(ModuleManager.enableModule, (address(module)));
        bytes memory signature = _prevalidatedSignature(OWNER);

        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("GS025"));
        Safe(payable(safe))
            .execTransaction(safe, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signature);

        assertFalse(Safe(payable(safe)).isModuleEnabled(address(module)), "still not enabled");
    }

    /// @dev Not even the owner may call `enableModule` directly. The only path is
    ///      a Safe transaction the Safe sends to itself — which is why the helper
    ///      must not shortcut it.
    function test_DirectEnableModuleRevertsEvenForOwner() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("GS031"));
        Safe(payable(safe)).enableModule(address(module));

        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("GS031"));
        Safe(payable(safe)).enableModule(address(module));
    }

    /*//////////////////////////////////////////////////////////////
              4. MODULE AUTHORITY IS REAL, AND EXCLUSIVE
    //////////////////////////////////////////////////////////////*/

    function test_EnabledModuleCanMoveTokensOutOfSafe() public {
        enableModule(safe, address(module), OWNER);

        uint256 amount = 250e18;
        assertTrue(module.pullToken(safe, address(token), RECIPIENT, amount), "module exec succeeded");

        assertEq(token.balanceOf(RECIPIENT), amount, "recipient credited");
        assertEq(token.balanceOf(safe), FUNDING - amount, "safe debited");
    }

    /// @dev The other half of the same fact. `rogueModule` is byte-for-byte
    ///      identical code to `module`; the only difference is that the Safe never
    ///      enabled it. An EOA is checked too, so the result cannot be attributed
    ///      to something about being a contract.
    function test_NonModuleCannotMoveTokensOutOfSafe() public {
        enableModule(safe, address(module), OWNER);

        bytes memory transferData = abi.encodeCall(IERC20.transfer, (RECIPIENT, FUNDING));

        // A contract that is not an enabled module.
        assertFalse(Safe(payable(safe)).isModuleEnabled(address(rogueModule)), "rogue not enabled");
        vm.expectRevert(bytes("GS104"));
        rogueModule.pullToken(safe, address(token), RECIPIENT, FUNDING);

        // An EOA calling the module entrypoint directly.
        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("GS104"));
        ModuleManager(safe).execTransactionFromModule(address(token), 0, transferData, Enum.Operation.Call);

        // The owner, too: owning the Safe is not the same as being its module.
        vm.prank(OWNER);
        vm.expectRevert(bytes("GS104"));
        ModuleManager(safe).execTransactionFromModule(address(token), 0, transferData, Enum.Operation.Call);

        assertEq(token.balanceOf(safe), FUNDING, "safe untouched");
        assertEq(token.balanceOf(RECIPIENT), 0, "recipient uncredited");
    }

    /// @dev `execTransactionFromModuleReturnData` is the variant `TradingModule`
    ///      will need (swap adapters return amounts), so confirm it is reachable
    ///      and that its return data survives the hop.
    function test_EnabledModuleCanUseReturnDataVariant() public {
        enableModule(safe, address(module), OWNER);

        vm.prank(address(module));
        (bool success, bytes memory returnData) = ModuleManager(safe)
            .execTransactionFromModuleReturnData(
                address(token), 0, abi.encodeCall(IERC20.balanceOf, (safe)), Enum.Operation.Call
            );

        assertTrue(success, "module exec succeeded");
        assertEq(abi.decode(returnData, (uint256)), FUNDING, "return data forwarded");
    }

    /*//////////////////////////////////////////////////////////////
                          HARNESS SANITY
    //////////////////////////////////////////////////////////////*/

    /// @dev `execAsOwner` uses safeTxGas = gasPrice = 0, which puts Safe in its
    ///      revert-on-inner-failure mode. Without that, a failing owner
    ///      transaction would return `false` and a test could pass while the thing
    ///      it asked for never happened.
    function test_ExecAsOwnerRevertsWhenInnerCallFails() public {
        // Enabling the sentinel is rejected by `enableModule` itself (GS101), so
        // the failure originates inside the Safe's own inner call.
        vm.expectRevert(bytes("GS013"));
        this.enableModuleExternal(safe, SENTINEL, OWNER);
    }

    /// @dev `expectRevert` needs an external call boundary; `enableModule` is internal.
    function enableModuleExternal(address safe_, address module_, address owner_) external {
        enableModule(safe_, module_, owner_);
    }
}
