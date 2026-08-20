// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {Safe} from "safe-contracts/Safe.sol";
import {SafeProxyFactory} from "safe-contracts/proxies/SafeProxyFactory.sol";
import {ModuleManager} from "safe-contracts/base/ModuleManager.sol";
import {Enum} from "safe-contracts/common/Enum.sol";

/// @title SafeDeployer
/// @notice Test-only harness that stands up a real Safe (v1.4.1) locally and
///         drives it the way an owner would.
/// @dev Inherit this into a test contract and call the `internal` helpers.
///
///      Three deliberate choices, because they are what make the A5 non-custody
///      argument testable rather than asserted:
///
///      1. The Safe singleton and `SafeProxyFactory` are deployed *in-process*
///         rather than read from their canonical mainnet/BSC addresses. Unit
///         tests therefore need no RPC and no fork. The fork test against real
///         PancakeSwap stays separate and is the only place a live chain is
///         required.
///
///      2. `enableModule` goes through a genuine Safe owner transaction —
///         `execTransaction` calling `enableModule(module)` on the Safe itself.
///         It does not poke the `modules` linked list with `vm.store`. The whole
///         point of building a Safe *module* is that the module's authority is
///         granted by Safe's own module mechanism; a test that writes that
///         storage by hand proves nothing about the mechanism it is meant to
///         exercise.
///
///      3. The helper never holds owner private keys, so signatures use Safe's
///         pre-validated form (see `_prevalidatedSignature`) rather than
///         `vm.sign`. That keeps owners as plain addresses and lets tests use
///         contract owners later without restructuring.
///
///      Not for production use — `internal` and test-scoped by design.
abstract contract SafeDeployer {
    /// @dev forge-std's cheatcode address. Held directly instead of inheriting
    ///      `Test` so this helper can be mixed into any test base.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Safe's sentinel node, the head of both the owner and module linked lists.
    address internal constant SENTINEL = address(0x1);

    /// @notice Locally deployed Safe singleton (the mastercopy proxies delegate to).
    Safe internal safeSingleton;

    /// @notice Locally deployed proxy factory.
    SafeProxyFactory internal safeProxyFactory;

    /// @dev Bumped per deployment so two Safes with identical owners/threshold in
    ///      one test get distinct addresses instead of colliding on CREATE2 salt.
    uint256 private _saltNonce;

    /*//////////////////////////////////////////////////////////////
                                DEPLOY
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a fresh Safe proxy owned by `owners` with `threshold`.
    /// @dev Deploys the singleton and factory lazily on first use, so a test that
    ///      never touches a Safe pays nothing and no explicit setup call is needed.
    ///      `setup` is passed through the proxy initializer, which is how a real
    ///      Safe is configured: no module, no fallback handler, no payment.
    /// @param owners Owner set, in Safe's expected form (no duplicates, no zero
    ///        address, no sentinel).
    /// @param threshold Signatures required per transaction; must be in [1, owners.length].
    /// @return safe Address of the deployed Safe proxy.
    function deploySafe(address[] memory owners, uint256 threshold) internal returns (address safe) {
        if (address(safeSingleton) == address(0)) {
            safeSingleton = new Safe();
            safeProxyFactory = new SafeProxyFactory();
            VM.label(address(safeSingleton), "SafeSingleton");
            VM.label(address(safeProxyFactory), "SafeProxyFactory");
        }

        bytes memory initializer = abi.encodeCall(
            Safe.setup,
            (
                owners,
                threshold,
                address(0), // to: no setup delegatecall
                "", // data
                address(0), // fallbackHandler
                address(0), // paymentToken
                0, // payment
                payable(address(0)) // paymentReceiver
            )
        );

        safe = address(safeProxyFactory.createProxyWithNonce(address(safeSingleton), initializer, _saltNonce++));
        VM.label(safe, "Safe");
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable `module` on `safe` via a real owner transaction.
    /// @dev The Safe calls `enableModule` on itself: `to` is the Safe, so
    ///      `ModuleManager.enableModule`'s `authorized` modifier
    ///      (`msg.sender == address(this)`) is satisfied legitimately. There is no
    ///      other way in — an owner cannot call `enableModule` directly (GS031).
    /// @param safe Safe to modify.
    /// @param module Module to whitelist.
    /// @param owner Owner submitting the transaction; must be an actual owner or
    ///        signature validation reverts (GS025).
    function enableModule(address safe, address module, address owner) internal {
        execAsOwner(safe, safe, abi.encodeCall(ModuleManager.enableModule, (module)), owner);
    }

    /// @notice Execute an owner transaction `safe -> to` carrying `data`.
    /// @dev `safeTxGas` and `gasPrice` are both zero, which puts Safe in its
    ///      "revert on inner failure" mode (`require(success || safeTxGas != 0 ||
    ///      gasPrice != 0)`, GS013). A failing inner call therefore surfaces as a
    ///      revert here rather than a silently-false return, which is what a test
    ///      wants.
    ///
    ///      The returned bytes are `execTransaction`'s own return data — the
    ///      ABI-encoded `bool success`. Safe discards the *inner* call's return
    ///      data on the owner path, so it is not recoverable here; a test needing
    ///      an inner return value must go through a module and
    ///      `execTransactionFromModuleReturnData`, or read resulting state.
    /// @param safe Safe to act through.
    /// @param to Call target.
    /// @param data Calldata for `to`.
    /// @param owner Owner submitting (and pre-validating) the transaction.
    /// @return returnData Raw return data of `execTransaction`.
    function execAsOwner(address safe, address to, bytes memory data, address owner)
        internal
        returns (bytes memory returnData)
    {
        bytes memory signatures = _prevalidatedSignature(owner);

        VM.prank(owner);
        (bool ok, bytes memory ret) = safe.call(
            abi.encodeCall(
                Safe.execTransaction,
                (
                    to,
                    0, // value
                    data,
                    Enum.Operation.Call,
                    0, // safeTxGas — zero, see @dev
                    0, // baseGas
                    0, // gasPrice — zero, so no refund logic runs
                    address(0), // gasToken
                    payable(address(0)), // refundReceiver
                    signatures
                )
            )
        );

        // Bubble the Safe's revert reason verbatim so tests can assert on GS0xx
        // codes instead of an opaque helper-level failure.
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /*//////////////////////////////////////////////////////////////
                              SIGNATURES
    //////////////////////////////////////////////////////////////*/

    /// @notice Build a single pre-validated Safe signature attributed to `owner`.
    /// @dev NOT a bypass. Safe defines four signature encodings, selected by the
    ///      `v` byte, and `v == 1` is the documented "approved hash" form:
    ///
    ///          Safe.sol, checkNSignatures:
    ///              } else if (v == 1) {
    ///                  currentOwner = address(uint160(uint256(r)));
    ///                  require(msg.sender == currentOwner
    ///                          || approvedHashes[currentOwner][dataHash] != 0, "GS025");
    ///
    ///      The owner is carried in `r`; `s` is unused. Safe accepts it only when
    ///      the transaction is submitted *by that owner* (or the owner pre-approved
    ///      the hash in an earlier transaction) — the `msg.sender == currentOwner`
    ///      check is the authentication, standing in for an ECDSA recovery that
    ///      would have produced the same address. It is the mechanism contract
    ///      owners and Safe's own `approveHash` flow use in production.
    ///
    ///      Consequences worth stating: a non-owner cannot forge one, because
    ///      `checkNSignatures` still walks the owner list and rejects an `r` that
    ///      is not an owner; and it cannot be used to act *for* another owner,
    ///      because `msg.sender` must match. For the 1-of-1 Safes in these tests
    ///      it is exactly equivalent to a real signature, without the helper
    ///      needing to know a private key.
    ///
    ///      Encoding is Safe's flat 65-byte layout: r (32) || s (32) || v (1).
    /// @param owner Owner the signature is attributed to.
    /// @return signature 65-byte pre-validated signature.
    function _prevalidatedSignature(address owner) internal pure returns (bytes memory signature) {
        return abi.encodePacked(
            bytes32(uint256(uint160(owner))), // r = owner
            bytes32(0), // s = unused
            uint8(1) // v = 1 -> pre-validated / approved-hash form
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read a Safe's enabled modules, starting from the sentinel.
    /// @dev Convenience wrapper over `getModulesPaginated` with a page size large
    ///      enough for tests; ignores the `next` cursor deliberately.
    /// @param safe Safe to inspect.
    /// @return modules Enabled modules, most recently added first.
    function safeModules(address safe) internal view returns (address[] memory modules) {
        (modules,) = Safe(payable(safe)).getModulesPaginated(SENTINEL, 10);
    }
}
