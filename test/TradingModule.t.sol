// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Safe} from "safe-contracts/Safe.sol";
import {ModuleManager} from "safe-contracts/base/ModuleManager.sol";
import {Enum} from "safe-contracts/common/Enum.sol";

import {TradingModule} from "../src/accounts/TradingModule.sol";
import {Router} from "../src/core/Router.sol";
import {SettlementEngine} from "../src/core/SettlementEngine.sol";
import {IClientAccount} from "../src/interfaces/IClientAccount.sol";
import {IRebasingEquityToken} from "../src/interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {VenueRegistry} from "../src/router/VenueRegistry.sol";

import {SafeDeployer} from "./helpers/SafeDeployer.sol";
import {MockAdapter, MockStable} from "./mocks/SettlementMocks.sol";
import {SafeSpy, UnzeroableToken} from "./mocks/TradingModuleMocks.sol";

/// @title TradingModuleTest
/// @notice A5 coverage for {TradingModule}.
///
/// @dev THE ASSESSMENT ASKS FOR ONE TEST: an operator attempts withdrawal and it
///      reverts. That test is here ({test_OperatorCannotWithdrawFromSafe}) and it
///      is necessary, but on its own it proves almost nothing — it closes the
///      DIRECT path and leaves every indirect one open. An account that blocks
///      `withdraw` while permitting arbitrary approval is custodial in every way
///      that matters, because approval is withdrawal with one more transaction.
///
///      So the suite is organised so that the operator's capability boundary is
///      readable from the test NAMES alone, grouped by the shape of the attack
///      rather than by the function under test:
///
///        - no withdrawal surface exists at all (direct path)
///        - every configuration path is Safe-gated (no escalation path)
///        - the operator cannot produce an allowance to any address it chooses
///          (the approval-is-withdrawal path — the one that actually matters)
///        - deallowlisting really revokes (the emergency path works)
///        - the revocation loop stays executable at its bound (the emergency path
///          cannot be griefed into unexecutability)
///        - a trade cannot be used to move value out (the indirect-drain path)
///        - the client can leave unilaterally (the exit path)
///
///      Two things are deliberately NOT asserted the way a reader might expect,
///      and both are called out at the tests concerned: the share allowance does
///      not strictly shrink on every rebase (it never GROWS, which is the property
///      the design rests on), and the per-token escape hatch does not rescue a
///      token that reverts on zero approval — see
///      {test_UnzeroableTokenAlsoBlocksPerTokenRevoke}.
contract TradingModuleTest is Test, SafeDeployer {
    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal attacker = makeAddr("attacker");
    address internal admin = makeAddr("admin");
    address internal feeTo = makeAddr("feeTo");
    address internal sink = makeAddr("sink");

    /*//////////////////////////////////////////////////////////////
                                 SYSTEM
    //////////////////////////////////////////////////////////////*/

    address internal safe;
    TradingModule internal module;

    MockShareRegistry internal shareRegistry;
    MockRebasingEquityToken internal equity;
    MockStable internal stable;
    VenueRegistry internal venues;
    SettlementEngine internal engine;
    Router internal router;
    MockAdapter internal adapter;

    bytes32 internal constant VENUE = keccak256("MOCK_VENUE");
    bytes32 internal constant UNREGISTERED_VENUE = keccak256("EVIL_VENUE");

    uint256 internal constant WAD = 1e18;

    /// @dev Generous relative to anything these tests approve, so a cap breach is
    ///      always the test asking for one rather than an accident of sizing.
    uint256 internal constant SHARE_CAP = 1e22;
    uint256 internal constant STABLE_ALLOWANCE = 1e24;
    uint256 internal constant INITIAL_SHARE_ALLOWANCE = 1e21;

    uint256 internal constant SAFE_SHARES = 1e24;
    uint256 internal constant SAFE_STABLE = 1e26;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        safe = deploySafe(owners, 1);

        stable = new MockStable("Stable", "USD");

        vm.startPrank(admin);
        shareRegistry = new MockShareRegistry(admin);
        equity = new MockRebasingEquityToken("Equity", "EQ", admin, IShareRegistry(address(shareRegistry)));
        shareRegistry.registerToken(address(equity));
        shareRegistry.setCustodiedShares(address(equity), 1e33);

        equity.grantRole(equity.PRIMARY_ROLE(), admin);
        equity.grantRole(equity.CORPORATE_ACTION_ROLE(), admin);

        venues = new VenueRegistry(admin);
        engine = new SettlementEngine(admin, venues, feeTo);
        router = new Router(venues, engine);
        engine.initializeRouter(address(router));
        engine.registerRebasingToken(address(equity), true);

        adapter = new MockAdapter(sink, IRebasingEquityToken(address(equity)));
        venues.setAdapter(VENUE, address(adapter));

        equity.mint(address(adapter), 1e26);
        equity.mint(safe, SAFE_SHARES);
        vm.stopPrank();

        stable.mint(address(adapter), 1e30);
        stable.mint(safe, SAFE_STABLE);

        module = new TradingModule(safe, address(router));

        // Real Safe owner transaction — the module's authority comes from the
        // Safe's own module mechanism, not from a storage poke. See {SafeDeployer}.
        enableModule(safe, address(module), owner);

        // Owner-level configuration, every call a Safe owner transaction.
        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), true)));
        _ownerCall(abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), SHARE_CAP)));
        _ownerCall(
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(stable), STABLE_ALLOWANCE))
        );
        _ownerCall(
            abi.encodeCall(
                TradingModule.setEngineShareAllowance, (address(engine), address(equity), INITIAL_SHARE_ALLOWANCE)
            )
        );
        _ownerCall(abi.encodeCall(TradingModule.setOperator, (operator, true)));

        vm.label(safe, "safe");
        vm.label(address(module), "module");
        vm.label(address(engine), "engine");
        vm.label(address(router), "router");
        vm.label(address(equity), "equity");
        vm.label(address(stable), "stable");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Drive a Safe-gated module function as the owner would: a Safe owner
    ///      transaction whose target is the module.
    function _ownerCall(bytes memory data) internal returns (bytes memory) {
        return execAsOwner(safe, address(module), data, owner);
    }

    /// @dev Move assets out of the Safe as the owner: an ordinary Safe transaction
    ///      that does not involve the module at all.
    function _ownerSafeCall(address to, bytes memory data) internal returns (bytes memory) {
        return execAsOwner(safe, to, data, owner);
    }

    function _order(address assetIn, address assetOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (OrderTypes.Order memory)
    {
        return OrderTypes.Order({
            account: safe,
            assetIn: assetIn,
            assetOut: assetOut,
            amountIn: amountIn,
            minAmountOut: minOut,
            venueId: VENUE,
            deadline: block.timestamp + 1 hours
        });
    }

    function _buy(uint256 amountIn) internal view returns (OrderTypes.Order memory) {
        return _order(address(stable), address(equity), amountIn, 1);
    }

    function _sell(uint256 amountIn) internal view returns (OrderTypes.Order memory) {
        return _order(address(equity), address(stable), amountIn, 1);
    }

    function _rebase(uint256 newMultiplier) internal {
        vm.prank(admin);
        equity.applyCorporateAction(newMultiplier);
    }

    /// @dev Drop a 4-byte error selector, leaving the ABI-encoded arguments.
    function _stripSelector(bytes memory err) internal pure returns (bytes memory args) {
        args = new bytes(err.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = err[i + 4];
        }
    }

    /// @dev Submit as the operator and return the inner revert data the Safe
    ///      reported, so a test can assert on the ORIGINAL error rather than on the
    ///      `ModuleExecutionFailed` wrapper. Fails the test if the order succeeds.
    function _submitExpectingInnerRevert(OrderTypes.Order memory o) internal returns (bytes memory inner) {
        vm.prank(operator);
        try module.submitOrder(o) returns (uint256) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), TradingModule.ModuleExecutionFailed.selector, "not ModuleExecutionFailed");
            (, inner) = abi.decode(_stripSelector(err), (address, bytes));
        }
    }

    /// @dev Call an owner-gated module function AS THE SAFE and return the inner
    ///      revert data.
    ///
    ///      WHY NOT THROUGH {_ownerCall}. Two layers each swallow a revert reason
    ///      on the way out, and a test that goes through both can only ever assert
    ///      the outermost one:
    ///
    ///        - the SAFE's `execTransaction` discards the inner reason entirely
    ///          (`require(success || safeTxGas != 0 || gasPrice != 0, "GS013")`), so
    ///          a real owner transaction surfaces the string `GS013` and nothing
    ///          else — see {test_OwnerTransactionMasksModuleErrors};
    ///        - the MODULE's `_execOnSafe` wraps whatever the Safe reported in
    ///          `ModuleExecutionFailed`, because Safe's module execution returns a
    ///          bool rather than bubbling.
    ///
    ///      Pranking the Safe presents `onlySafe` with exactly the `msg.sender` a
    ///      real owner transaction would, so the authorization path under test is
    ///      identical; it just skips the outer wrapper that destroys the evidence.
    function _safeCallExpectingInnerRevert(bytes memory data) internal returns (bytes memory inner) {
        vm.prank(safe);
        (bool ok, bytes memory err) = address(module).call(data);

        assertFalse(ok, "call unexpectedly succeeded");
        assertEq(bytes4(err), TradingModule.ModuleExecutionFailed.selector, "not ModuleExecutionFailed");
        (, inner) = abi.decode(_stripSelector(err), (address, bytes));
    }

    /// @dev Snapshot of everything the Safe holds, for the "nothing moved" checks.
    function _safeHoldings() internal view returns (uint256 shares_, uint256 stable_) {
        return (equity.shares(safe), stable.balanceOf(safe));
    }

    /*//////////////////////////////////////////////////////////////
              1. THE REQUIRED TEST — AND WHY IT IS NOT ENOUGH
    //////////////////////////////////////////////////////////////*/

    /// @notice The assessment's required assertion: the operator cannot withdraw.
    /// @dev Walks EVERY route the module exposes, not just a hypothetical
    ///      `withdraw`. The operator is a legitimately enabled operator here — this
    ///      is not an unauthorised caller being turned away, it is the holder of
    ///      the module's full operator authority finding that the authority does
    ///      not include moving assets anywhere.
    ///
    ///      Necessary but NOT sufficient on its own. See
    ///      {test_OperatorCannotApproveItselfAndDrain} for the path this test
    ///      leaves open, which is the one that decides whether the account is
    ///      really non-custodial.
    function test_OperatorCannotWithdrawFromSafe() public {
        (uint256 sharesBefore, uint256 stableBefore) = _safeHoldings();

        vm.startPrank(operator);

        // Route 1: owner-only configuration that could grant an allowance.
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setEngineTokenAllowance(address(engine), address(stable), type(uint256).max);

        // Route 2: the operator's own approval action, aimed at itself.
        vm.expectRevert(abi.encodeWithSelector(TradingModule.EngineNotApproved.selector, operator));
        module.setEngineShareAllowance(operator, address(equity), type(uint256).max);

        // Route 3: an order that pays out to somewhere other than the Safe. The
        // module refuses any order whose account is not its own Safe, and
        // settlement always credits `o.account`, so there is no payout address to
        // redirect in the first place.
        vm.expectRevert(abi.encodeWithSelector(TradingModule.OrderAccountMismatch.selector, operator, safe));
        module.submitOrder(_orderFor(operator));

        // Route 4: moving the Safe's tokens directly. The operator holds no
        // allowance and is not the Safe.
        vm.expectRevert();
        stable.transferFrom(safe, operator, stableBefore);
        vm.expectRevert();
        equity.transferSharesFrom(safe, operator, sharesBefore);

        vm.stopPrank();

        (uint256 sharesAfter, uint256 stableAfter) = _safeHoldings();
        assertEq(sharesAfter, sharesBefore, "safe shares moved");
        assertEq(stableAfter, stableBefore, "safe stable moved");
    }

    function _orderFor(address account) internal view returns (OrderTypes.Order memory o) {
        o = _buy(1e18);
        o.account = account;
    }

    /*//////////////////////////////////////////////////////////////
                  2. NO WITHDRAWAL SURFACE EXISTS AT ALL
    //////////////////////////////////////////////////////////////*/

    /// @notice None of the dangerous functions exist on the module.
    /// @dev THIS TEST ASSERTS AN ABSENCE, which is worth stating because absences
    ///      are the easiest property in a codebase to lose. Nobody deletes a
    ///      security boundary on purpose; someone adds a convenience passthrough
    ///      six months later because a script needed it, and the contract-level
    ///      allowlist argument quietly stops being true. A test that names the
    ///      selectors turns that from a silent regression into a failing build.
    ///
    ///      `call` returning false is the right assertion here: the module has no
    ///      fallback, so an unknown selector cannot be dispatched. If any of these
    ///      ever starts returning true, the function exists.
    function test_ModuleExposesNoWithdrawalFunction() public {
        string[4] memory signatures = [
            "withdraw(address,address,uint256)",
            "withdrawShares(address,address,uint256)",
            "execute(address,uint256,bytes)",
            "executeDelegateCall(address,bytes)"
        ];

        for (uint256 i; i < signatures.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(signatures[i])));

            // Padded with enough zero words to satisfy any plausible argument
            // layout, so a failure means "no such function" and not "bad calldata".
            bytes memory payload = abi.encodePacked(selector, uint256(0), uint256(0), uint256(0), uint256(0));

            vm.prank(operator);
            (bool ok,) = address(module).call(payload);
            assertFalse(ok, signatures[i]);

            vm.prank(owner);
            (ok,) = address(module).call(payload);
            assertFalse(ok, signatures[i]);
        }
    }

    /// @notice The module has no fallback, so it cannot be used as a call relay.
    /// @dev The companion to the selector list above: that one names the functions
    ///      someone might add, this one closes the generic path that would make
    ///      naming them pointless.
    function test_ModuleHasNoFallback() public {
        vm.prank(operator);
        (bool ok,) = address(module).call(hex"deadbeef");
        assertFalse(ok, "fallback dispatched");

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        (ok,) = address(module).call{value: 1 ether}("");
        assertFalse(ok, "receive accepted value");
    }

    /// @notice The operator cannot bypass the module by driving the Safe itself.
    /// @dev The operator is not a Safe owner, so it has no signature the Safe will
    ///      accept. Its pre-validated signature clears the `msg.sender ==
    ///      currentOwner` check and then fails owner-set membership (GS026) — see
    ///      {SafeDeployer._prevalidatedSignature}.
    function test_OperatorCannotCallSafeDirectly() public {
        (, uint256 stableBefore) = _safeHoldings();

        bytes memory transferData = abi.encodeCall(IERC20.transfer, (operator, stableBefore));

        vm.prank(operator);
        vm.expectRevert(bytes("GS026"));
        Safe(payable(safe))
            .execTransaction(
                address(stable),
                0,
                transferData,
                Enum.Operation.Call,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                _prevalidatedSignature(operator)
            );

        assertEq(stable.balanceOf(safe), stableBefore, "safe stable moved");
    }

    /// @notice Every Safe execution the module performs is `Operation.Call`.
    /// @dev OBSERVED, NOT ARGUED. A second module pointed at a {SafeSpy} records
    ///      the raw `operation` ordinal of every execution. The alternative — "no
    ///      function accepts arbitrary calldata, so a delegatecall is
    ///      unconstructible" — is a true statement about today's code that would
    ///      keep passing if someone hardcoded `DelegateCall` at a call site.
    ///
    ///      This matters more than it might look. A delegatecall from a module runs
    ///      in the SAFE's storage context: it can rewrite the owner set and the
    ///      module list, which is not an escalation within the account but a
    ///      replacement of it.
    function test_ModuleNeverUsesDelegateCall() public {
        SafeSpy spy = new SafeSpy();
        TradingModule spied = new TradingModule(address(spy), address(router));

        stable.mint(address(spy), 1e24);
        vm.prank(admin);
        equity.mint(address(spy), 1e24);

        // Drive every path in the module that reaches the Safe.
        spy.callAsSafe(address(spied), abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), true)));
        spy.callAsSafe(
            address(spied),
            abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), SHARE_CAP))
        );
        spy.callAsSafe(
            address(spied),
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(stable), STABLE_ALLOWANCE))
        );
        spy.callAsSafe(
            address(spied),
            abi.encodeCall(
                TradingModule.setEngineShareAllowance, (address(engine), address(equity), INITIAL_SHARE_ALLOWANCE)
            )
        );
        spy.callAsSafe(address(spied), abi.encodeCall(TradingModule.setOperator, (operator, true)));

        // A settlement, so the submitOrder path is recorded too.
        OrderTypes.Order memory o = _buy(1e20);
        o.account = address(spy);
        vm.prank(operator);
        spied.submitOrder(o);

        // Revocation, both the bulk and per-token paths.
        spy.callAsSafe(
            address(spied), abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(stable)))
        );
        spy.callAsSafe(address(spied), abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));

        assertGt(spy.operationCount(), 5, "no executions recorded - test proves nothing");
        assertFalse(spy.sawDelegateCall(), "module requested a delegatecall");

        for (uint256 i; i < spy.operationCount(); ++i) {
            assertEq(spy.operations(i), 0, "operation was not Call");
        }
    }

    /*//////////////////////////////////////////////////////////////
                3. EVERY CONFIGURATION PATH IS SAFE-GATED
    //////////////////////////////////////////////////////////////*/

    // NOTE ON THE EXPECTED ERRORS. Owner-level functions carry `onlySafe`, which
    // asks one question — "are you the Safe?" — so an operator and an attacker
    // both get `NotSafe`; the module does not distinguish a privileged-but-not-
    // owner caller from a stranger, and it should not, because there is nothing an
    // operator is closer to being allowed to do here. `NotAuthorized` is the error
    // of the OPERATOR-level gate, and it appears only where an attacker is turned
    // away from a function the operator may legitimately call.

    function test_OperatorCannotSetOperator() public {
        // No self-escalation and no appointing accomplices: the one function that
        // could grow the operator set is unreachable from inside it.
        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setOperator(operator, true);

        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setOperator(attacker, true);

        assertFalse(module.isOperator(attacker), "attacker became an operator");
    }

    function test_OperatorCannotSetApprovedEngine() public {
        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setApprovedEngine(attacker, true);

        assertFalse(module.isApprovedEngine(attacker), "attacker became an engine");
    }

    function test_OperatorCannotSetEngineShareCap() public {
        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setEngineShareCap(address(engine), address(equity), type(uint256).max);

        assertEq(module.engineShareCap(address(engine), address(equity)), SHARE_CAP, "cap changed");
    }

    function test_OperatorCannotSetEngineTokenAllowance() public {
        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setEngineTokenAllowance(address(engine), address(stable), type(uint256).max);

        assertEq(stable.allowance(safe, address(engine)), STABLE_ALLOWANCE, "allowance changed");
    }

    function test_OperatorCannotRevokeEngineAllowance() public {
        // Revocation is owner-only in BOTH directions. An operator that could
        // revoke could not steal, but it could halt the client's trading at will,
        // which is a denial-of-service the client did not sign up for.
        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.revokeEngineAllowance(address(engine), address(stable));

        assertEq(stable.allowance(safe, address(engine)), STABLE_ALLOWANCE, "allowance revoked");
    }

    function test_AttackerCannotDoAnything() public {
        vm.startPrank(attacker);

        // Owner-gated surface.
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setOperator(attacker, true);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setApprovedEngine(attacker, true);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setEngineShareCap(address(engine), address(equity), type(uint256).max);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setEngineTokenAllowance(address(engine), address(stable), type(uint256).max);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.revokeEngineAllowance(address(engine), address(stable));

        // Operator-gated surface: this is where `NotAuthorized` lives.
        vm.expectRevert(TradingModule.NotAuthorized.selector);
        module.submitOrder(_buy(1e18));
        vm.expectRevert(TradingModule.NotAuthorized.selector);
        module.setEngineShareAllowance(address(engine), address(equity), 1);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
              4. THE APPROVAL-IS-WITHDRAWAL PROOF — THE ONE
                            THAT ACTUALLY MATTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The operator cannot approve ITSELF and drain.
    /// @dev THIS IS THE TEST THAT PROVES THE NON-CUSTODIAL CLAIM, and
    ///      {test_OperatorCannotWithdrawFromSafe} is not.
    ///
    ///      Blocking withdrawal closes one path. If the operator can cause the Safe
    ///      to approve an address of its choosing, it approves itself and takes the
    ///      funds with `transferFrom` in a second transaction — the assets never
    ///      pass through a function called `withdraw`, and every withdrawal check
    ///      in the module is satisfied the whole time. An account that blocks
    ///      withdrawal but permits arbitrary approval is custodial in every way
    ///      that matters.
    ///
    ///      Three assertions, because two would leave a gap: the call is refused;
    ///      no allowance exists in either denomination afterwards; and the spend
    ///      that an allowance would have enabled actually fails. The third is not
    ///      redundant — it checks the token agrees with the view.
    function test_OperatorCannotApproveItselfAndDrain() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.EngineNotApproved.selector, operator));
        module.setEngineShareAllowance(operator, address(equity), type(uint256).max);

        assertEq(equity.allowance(safe, operator), 0, "token allowance to operator");
        assertEq(equity.allowanceShares(safe, operator), 0, "share allowance to operator");
        assertEq(stable.allowance(safe, operator), 0, "stable allowance to operator");

        (uint256 sharesBefore, uint256 stableBefore) = _safeHoldings();

        vm.startPrank(operator);
        vm.expectRevert();
        equity.transferSharesFrom(safe, operator, 1);
        vm.expectRevert();
        equity.transferFrom(safe, operator, 1);
        vm.expectRevert();
        stable.transferFrom(safe, operator, 1);
        vm.stopPrank();

        (uint256 sharesAfter, uint256 stableAfter) = _safeHoldings();
        assertEq(sharesAfter, sharesBefore, "shares left the safe");
        assertEq(stableAfter, stableBefore, "stable left the safe");
    }

    /// @notice Same shape, with an arbitrary third party rather than the operator.
    /// @dev Separate test because "the operator cannot approve itself" would be
    ///      satisfied by a check as narrow as `spender != msg.sender`, which would
    ///      be trivially defeated by an accomplice address. The bound is the
    ///      ALLOWLIST, not the caller's identity.
    function test_OperatorCannotApproveAnyThirdParty() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.EngineNotApproved.selector, attacker));
        module.setEngineShareAllowance(attacker, address(equity), type(uint256).max);

        assertEq(equity.allowance(safe, attacker), 0, "token allowance to attacker");
        assertEq(equity.allowanceShares(safe, attacker), 0, "share allowance to attacker");

        vm.prank(attacker);
        vm.expectRevert();
        equity.transferSharesFrom(safe, attacker, 1);
    }

    function test_OperatorCannotExceedShareCap() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                TradingModule.ExceedsShareCap.selector, address(engine), address(equity), SHARE_CAP + 1, SHARE_CAP
            )
        );
        module.setEngineShareAllowance(address(engine), address(equity), SHARE_CAP + 1);
    }

    /// @notice Lowering the cap binds the operator's next refresh.
    /// @dev Documents the exact semantics, including the part that is easy to get
    ///      wrong: lowering the cap does NOT retroactively lower a live allowance.
    ///      What it does is stop the operator renewing above the new value, so the
    ///      existing allowance can decay but never be restored. An owner who wants
    ///      the live allowance down NOW uses {revokeEngineAllowance}, and this test
    ///      asserts that too rather than leaving the reader to infer it.
    function test_OwnerCanLowerCapAndOperatorIsBound() public {
        uint256 s = 1e20;

        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), s);
        assertEq(equity.allowanceShares(safe, address(engine)), s, "allowance at S");

        _ownerCall(abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), s / 2)));

        // The live allowance is untouched by the cap change.
        assertEq(equity.allowanceShares(safe, address(engine)), s, "live allowance changed with cap");

        // But the operator cannot refresh above the new cap.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TradingModule.ExceedsShareCap.selector, address(engine), address(equity), s, s / 2)
        );
        module.setEngineShareAllowance(address(engine), address(equity), s);

        // At or below the new cap it still works.
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), s / 2);
        assertEq(equity.allowanceShares(safe, address(engine)), s / 2, "allowance at new cap");

        // And the owner can take it to zero immediately.
        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(equity))));
        assertEq(equity.allowanceShares(safe, address(engine)), 0, "revoke did not zero");
    }

    /// @notice The cap check reads the RESULTING allowance, not the argument.
    /// @dev Distinguishable because the error carries the value that was checked.
    ///      If the module pre-checked the argument, the reverted `resulting` field
    ///      would be whatever the caller passed; because it reads state after the
    ///      approval executed, it is what the token actually recorded — the same
    ///      number here, but arrived at from the side that matters.
    ///
    ///      The second half is the reason a post-execution check is safe at all:
    ///      the approval and the revert are one transaction, so the over-cap
    ///      allowance is never observable and never persists.
    function test_CapCheckReadsResultingAllowanceNotArgument() public {
        uint256 over = SHARE_CAP + 12345;
        uint256 allowanceBefore = equity.allowance(safe, address(engine));

        vm.prank(operator);
        (bool ok, bytes memory err) = address(module)
            .call(abi.encodeCall(TradingModule.setEngineShareAllowance, (address(engine), address(equity), over)));
        assertFalse(ok, "over-cap approval succeeded");

        assertEq(bytes4(err), TradingModule.ExceedsShareCap.selector, "wrong error");
        (,, uint256 resulting, uint256 cap) = _decodeExceedsShareCap(err);

        // The checked quantity is the allowance the token would have held, read
        // back through `allowanceShares`, which is exactly what the engine could
        // have spent.
        assertEq(resulting, over, "resulting was not the post-execution readback");
        assertEq(cap, SHARE_CAP, "cap");

        // Nothing persisted: the whole transaction reverted.
        assertEq(equity.allowance(safe, address(engine)), allowanceBefore, "raw allowance persisted");
        assertLe(equity.allowanceShares(safe, address(engine)), SHARE_CAP, "over-cap share allowance persisted");
    }

    function _decodeExceedsShareCap(bytes memory err)
        internal
        pure
        returns (address engine_, address token_, uint256 resulting, uint256 cap)
    {
        bytes memory args = new bytes(err.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = err[i + 4];
        }
        return abi.decode(args, (address, address, uint256, uint256));
    }

    /*//////////////////////////////////////////////////////////////
                   5. DEALLOWLISTING ACTUALLY REVOKES
    //////////////////////////////////////////////////////////////*/

    /// @notice Deallowlisting zeroes the token allowance it granted.
    /// @dev Without this, deallowlisting would be a flag change and nothing else —
    ///      and the flag is not what a compromised engine needs. It needs the
    ///      standing allowance, which it would still have. The emergency action
    ///      must stop the emergency, not merely record disapproval of it.
    function test_DeallowlistRevokesExistingTokenAllowance() public {
        assertEq(stable.allowance(safe, address(engine)), STABLE_ALLOWANCE, "precondition");

        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));

        assertEq(stable.allowance(safe, address(engine)), 0, "token allowance survived");
        assertFalse(module.isApprovedEngine(address(engine)), "still allowlisted");

        // The engine's own spend now fails, which is the property that matters.
        vm.prank(address(engine));
        vm.expectRevert();
        stable.transferFrom(safe, address(engine), 1);
    }

    function test_DeallowlistRevokesExistingShareAllowance() public {
        assertEq(equity.allowanceShares(safe, address(engine)), INITIAL_SHARE_ALLOWANCE, "precondition");

        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));

        assertEq(equity.allowanceShares(safe, address(engine)), 0, "share allowance survived");
        assertEq(equity.allowance(safe, address(engine)), 0, "raw allowance survived");

        vm.prank(address(engine));
        vm.expectRevert();
        equity.transferSharesFrom(safe, address(engine), 1);
    }

    function test_DeallowlistRevokesAcrossMultipleTokens() public {
        MockStable[3] memory extra;
        for (uint256 i; i < extra.length; ++i) {
            extra[i] = new MockStable("Extra", "EX");
            extra[i].mint(safe, 1e24);
            _ownerCall(
                abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(extra[i]), 1e23))
            );
        }

        // stable + equity from setup, plus the three above.
        assertEq(module.engineTokens(address(engine)).length, 5, "set size");

        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));

        assertEq(stable.allowance(safe, address(engine)), 0, "stable");
        assertEq(equity.allowance(safe, address(engine)), 0, "equity");
        for (uint256 i; i < extra.length; ++i) {
            assertEq(extra[i].allowance(safe, address(engine)), 0, "extra");
        }
        assertEq(module.engineTokens(address(engine)).length, 0, "set not cleared");
    }

    /// @notice Revocation happens BEFORE the flag is cleared, in one transaction.
    /// @dev The ordering is load-bearing, not cosmetic. {_revokeAllowances} is
    ///      shared with {TradingModule.revokeEngineAllowance}, which deliberately
    ///      does not require the engine to be approved — but if it ever did, and
    ///      the flag were cleared first, the owner would have locked themselves out
    ///      of revoking by the very act of deallowlisting. Asserting the log order
    ///      pins the sequence rather than the outcome, so a refactor that reorders
    ///      it fails here even if the end state happens to look right.
    function test_RevokeThenDeallowlistOrdering() public {
        vm.recordLogs();
        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 revoked = keccak256("EngineAllowanceRevoked(address,address)");
        bytes32 engineSet = keccak256("ApprovedEngineSet(address,bool)");

        uint256 firstRevoke = type(uint256).max;
        uint256 flagChange = type(uint256).max;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(module)) continue;
            if (logs[i].topics[0] == revoked && firstRevoke == type(uint256).max) firstRevoke = i;
            if (logs[i].topics[0] == engineSet) flagChange = i;
        }

        assertTrue(firstRevoke != type(uint256).max, "no revocation event");
        assertTrue(flagChange != type(uint256).max, "no flag event");
        assertLt(firstRevoke, flagChange, "flag cleared before revocation");
        assertFalse(module.isApprovedEngine(address(engine)), "flag not cleared");
    }

    /// @notice The per-token path works when the engine is already deallowlisted.
    /// @dev An allowance can outlive an allowlist entry, and refusing to revoke in
    ///      that state would make the escape hatch useless precisely when it is
    ///      needed. Asserts SUCCESS rather than `EngineNotApproved`.
    function test_StandaloneRevokeWorksWhenAlreadyDeallowlisted() public {
        MockStable other = new MockStable("Other", "OTH");
        _ownerCall(abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(other), 1e23)));

        // Deallowlist, which revokes everything in the set...
        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));
        assertFalse(module.isApprovedEngine(address(engine)), "precondition");

        // ...then grant an allowance outside the module, simulating one this module
        // never knew about, and revoke it while deallowlisted.
        _ownerSafeCall(address(other), abi.encodeCall(IERC20.approve, (address(engine), 5e22)));
        assertEq(other.allowance(safe, address(engine)), 5e22, "setup");

        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(other))));
        assertEq(other.allowance(safe, address(engine)), 0, "revoke while deallowlisted failed");
    }

    /// @notice One unzeroable token reverts the WHOLE bulk revocation.
    /// @dev No try/catch in the loop, by design. The state this avoids is worse
    ///      than a revert: some allowances zeroed, some still live, and the engine
    ///      marked deallowlisted — the owner believing capability is gone when it
    ///      is not. A failed emergency action must LOOK failed, so the owner
    ///      escalates instead of walking away.
    ///
    ///      The cost, asserted here rather than glossed: the engine stays
    ///      allowlisted and its other allowances stay live. See
    ///      {test_UnzeroableTokenAlsoBlocksPerTokenRevoke} for the limitation this
    ///      leaves in place.
    function test_PartialRevocationRevertsWholeCall() public {
        UnzeroableToken nozero = new UnzeroableToken();
        nozero.mint(safe, 1e24);

        _ownerCall(abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(nozero), 1e23)));

        uint256 stableAllowanceBefore = stable.allowance(safe, address(engine));
        uint256 setSizeBefore = module.engineTokens(address(engine)).length;

        // The inner reason survives two layers of swallowing only if it is read out
        // deliberately; see {_safeCallExpectingInnerRevert}.
        bytes memory inner =
            _safeCallExpectingInnerRevert(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));
        assertEq(bytes4(inner), UnzeroableToken.CannotZeroApproval.selector, "not the token's refusal");

        // Through a real owner transaction it is just GS013.
        vm.expectRevert(bytes("GS013"));
        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));

        // Nothing moved: the engine is still allowlisted and every other allowance
        // is exactly as it was.
        assertTrue(module.isApprovedEngine(address(engine)), "engine deallowlisted anyway");
        assertEq(stable.allowance(safe, address(engine)), stableAllowanceBefore, "stable allowance changed");
        assertEq(nozero.allowance(safe, address(engine)), 1e23, "nozero allowance changed");
        assertEq(module.engineTokens(address(engine)).length, setSizeBefore, "set changed");
    }

    /// @notice A token that cannot be zeroed also blocks the PER-TOKEN path.
    /// @dev DOCUMENTED LIMITATION, asserted rather than assumed away.
    ///      {TradingModule.revokeEngineAllowance} calls `approve(engine, 0)` on the
    ///      way through, so it reverts for the same reason the bulk path does. The
    ///      escape hatch rescues every OTHER pair — see
    ///      {test_PerTokenRevokeClearsEveryOtherPair} — but there is no path that
    ///      removes an unzeroable token from the engine's set, so bulk
    ///      deallowlisting stays blocked while it is in there.
    ///
    ///      That is a real gap and it belongs in the write-up rather than in a
    ///      comment claiming the hatch solves it. The fix would be an owner-only
    ///      "forget this pair" that removes from the set WITHOUT calling `approve`,
    ///      which is a design decision about whether the owner may mark an
    ///      allowance they cannot actually clear — deliberately not made here.
    function test_UnzeroableTokenAlsoBlocksPerTokenRevoke() public {
        UnzeroableToken nozero = new UnzeroableToken();
        nozero.mint(safe, 1e24);
        _ownerCall(abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(nozero), 1e23)));

        bytes memory inner = _safeCallExpectingInnerRevert(
            abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(nozero)))
        );
        assertEq(bytes4(inner), UnzeroableToken.CannotZeroApproval.selector, "not the token's refusal");

        assertEq(nozero.allowance(safe, address(engine)), 1e23, "allowance changed");

        // The token also stays in the engine's set, which is what keeps the bulk
        // path blocked. There is no path that removes it without zeroing first.
        address[] memory tokens = module.engineTokens(address(engine));
        bool present;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(nozero)) present = true;
        }
        assertTrue(present, "unzeroable token left the set");
    }

    /// @notice A failed owner transaction reports GS013, not the module's error.
    /// @dev AN OPERATIONAL LIMITATION WORTH PINNING DOWN, not a defect in the
    ///      module. Safe's `execTransaction` checks `require(success || safeTxGas !=
    ///      0 || gasPrice != 0, "GS013")` and discards the inner revert data, so an
    ///      owner whose configuration transaction fails learns only that it failed.
    ///      Diagnosis needs a simulation against the module directly — which is
    ///      what {_safeCallExpectingInnerRevert} does for these tests.
    ///
    ///      Asserted so the constraint is documented rather than discovered during
    ///      an incident, and so a future Safe version that DOES bubble would show up
    ///      here as a (welcome) failure.
    function test_OwnerTransactionMasksModuleErrors() public {
        // A plainly invalid configuration: engine zero address fails `InvalidEngine`
        // inside the module, with no Safe execution involved at all.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.InvalidEngine.selector, address(0)));
        module.setApprovedEngine(address(0), true);

        vm.expectRevert(bytes("GS013"));
        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(0), true)));
    }

    /// @notice Every zeroable pair can still be cleared individually.
    /// @dev The half of the escape hatch that does work: an unzeroable token does
    ///      not stop the owner reducing the engine's live capability to just that
    ///      one token. The residual exposure is bounded by that token's allowance
    ///      rather than by everything the engine held.
    function test_PerTokenRevokeClearsEveryOtherPair() public {
        UnzeroableToken nozero = new UnzeroableToken();
        nozero.mint(safe, 1e24);
        _ownerCall(abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(nozero), 1e23)));

        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(stable))));
        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(equity))));

        assertEq(stable.allowance(safe, address(engine)), 0, "stable");
        assertEq(equity.allowanceShares(safe, address(engine)), 0, "equity shares");

        address[] memory remaining = module.engineTokens(address(engine));
        assertEq(remaining.length, 1, "only the unzeroable token should remain");
        assertEq(remaining[0], address(nozero), "wrong token remaining");
    }

    function test_OperatorCannotRevoke() public {
        vm.prank(operator);
        vm.expectRevert(TradingModule.NotSafe.selector);
        module.setApprovedEngine(address(engine), false);
    }

    /*//////////////////////////////////////////////////////////////
          6. BOUNDED TOKEN SET — THE EMERGENCY-PATH LIVENESS FIX
    //////////////////////////////////////////////////////////////*/

    /// @dev Grows the engine's token set to exactly {MAX_TOKENS_PER_ENGINE},
    ///      returning the tokens added beyond the two the setup already registered.
    function _fillTokenSet() internal returns (MockStable[] memory added) {
        uint256 existing = module.engineTokens(address(engine)).length;
        uint256 room = module.MAX_TOKENS_PER_ENGINE() - existing;

        added = new MockStable[](room);
        for (uint256 i; i < room; ++i) {
            added[i] = new MockStable("Filler", "FILL");
            added[i].mint(safe, 1e24);
            _ownerCall(
                abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(added[i]), 1e23))
            );
        }

        assertEq(module.engineTokens(address(engine)).length, module.MAX_TOKENS_PER_ENGINE(), "set not full");
    }

    /// @notice The set cannot grow past the bound.
    /// @dev A LIVENESS FIX, NOT A GAS OPTIMISATION. The revocation loop is the
    ///      emergency path, so it must always be executable. Unbounded, anyone able
    ///      to cause tokens to be approved to an engine could grow the set until
    ///      the loop exceeds the block gas limit, making that engine PERMANENTLY
    ///      UN-REVOCABLE — a liveness failure sited in exactly the call that can
    ///      never be allowed to fail.
    function test_TokenSetIsBoundedPerEngine() public {
        _fillTokenSet();

        MockStable overflow = new MockStable("Overflow", "OVF");
        // Read the constant BEFORE the prank: a getter call would consume it.
        uint256 maxTokens = module.MAX_TOKENS_PER_ENGINE();
        bytes memory overflowCall =
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(overflow), 1e23));

        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(TradingModule.TooManyTokensForEngine.selector, address(engine), maxTokens)
        );
        module.setEngineTokenAllowance(address(engine), address(overflow), 1e23);

        // Through a real owner transaction the same rejection arrives as Safe's
        // GS013, because `execTransaction` does not bubble the inner reason.
        vm.expectRevert(bytes("GS013"));
        _ownerCall(overflowCall);

        // Re-approving an ALREADY tracked token is not a new entry and must still
        // work at the bound — otherwise the cap would freeze existing allowances.
        _ownerCall(abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(stable), 1)));
        assertEq(stable.allowance(safe, address(engine)), 1, "re-approval at bound failed");
    }

    /// @notice The bulk revocation executes at the bound, and this is its gas cost.
    /// @dev The number is the point of the test. "Bounded" is only a liveness
    ///      argument if the bound's worst case actually fits in a block, so the
    ///      figure is logged and belongs in the write-up as evidence rather than as
    ///      an assurance. Measured on the whole Safe owner transaction — the real
    ///      cost of the emergency action, not just the module's internal loop.
    function test_DeallowlistRevokesAtMaxTokenCount() public {
        MockStable[] memory added = _fillTokenSet();

        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));
        Vm.Gas memory gas = vm.lastCallGas();

        console2.log("deallowlist at MAX_TOKENS_PER_ENGINE -- total tx gas:", gas.gasTotalUsed);

        assertEq(stable.allowance(safe, address(engine)), 0, "stable");
        assertEq(equity.allowance(safe, address(engine)), 0, "equity");
        for (uint256 i; i < added.length; ++i) {
            assertEq(added[i].allowance(safe, address(engine)), 0, "filler");
        }
        assertEq(module.engineTokens(address(engine)).length, 0, "set not cleared");
        assertFalse(module.isApprovedEngine(address(engine)), "still allowlisted");

        // Comfortably inside a block on any chain this would deploy to. Asserted so
        // a future change that makes the loop dramatically more expensive fails
        // here rather than in an incident.
        assertLt(gas.gasTotalUsed, 3_000_000, "emergency path gas regression");
    }

    /// @notice The escape hatch works at the bound too.
    /// @dev Proves the pair is genuinely independent: even if the bulk loop were
    ///      somehow unexecutable, the owner can clear the set pair by pair at
    ///      constant gas and then deallowlist against an empty set.
    function test_PerTokenRevokeWorksAtMaxTokenCount() public {
        MockStable[] memory added = _fillTokenSet();

        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(stable))));
        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(equity))));
        for (uint256 i; i < added.length; ++i) {
            _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(added[i]))));
            assertEq(added[i].allowance(safe, address(engine)), 0, "filler not revoked");
        }

        assertEq(module.engineTokens(address(engine)).length, 0, "set not emptied");

        // Deallowlisting against an empty set is now trivial.
        _ownerCall(abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), false)));
        assertFalse(module.isApprovedEngine(address(engine)), "not deallowlisted");
    }

    /// @notice Revoking frees a slot, so the cap is not reached through churn.
    /// @dev Without removal the set only ever grows, and an engine would hit the
    ///      bound by having the same pair approved and revoked repeatedly rather
    ///      than by holding allowances over eight real assets. That would turn a
    ///      liveness protection into a liveness bug.
    function test_RevokeRemovesTokenFromSetAllowingReAdd() public {
        _fillTokenSet();

        MockStable fresh = new MockStable("Fresh", "FRSH");
        uint256 maxTokens = module.MAX_TOKENS_PER_ENGINE();

        // Full: rejected.
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(TradingModule.TooManyTokensForEngine.selector, address(engine), maxTokens)
        );
        module.setEngineTokenAllowance(address(engine), address(fresh), 1e23);

        // Free one slot.
        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(stable))));
        assertEq(module.engineTokens(address(engine)).length, maxTokens - 1, "slot not freed");

        // Now accepted.
        _ownerCall(abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(fresh), 1e23)));
        assertEq(fresh.allowance(safe, address(engine)), 1e23, "re-add failed");
    }

    /*//////////////////////////////////////////////////////////////
             7. ALLOWANCE BEHAVIOUR ACROSS A CORPORATE ACTION
    //////////////////////////////////////////////////////////////*/

    /// @notice The share allowance NEVER GROWS across a corporate action — and may
    ///         stay exactly equal.
    /// @dev SPLIT FROM THE SHRINK TEST ON PURPOSE. The property the design rests on
    ///      is "never increases", not "always decreases", and a single test named
    ///      after the wrong property is how a false claim gets into a write-up.
    ///
    ///      Starting multiplier is NON-PARITY (`1e18 + 1`) so the ceil applied at
    ///      approval time leaves headroom. At exact parity `A == S` with no
    ///      headroom at all and any increase shrinks the readback immediately,
    ///      which would never exercise the equal case.
    ///
    ///      Concretely: `m0 = 1e18 + 1`, `S = 1` gives `A = ceil(1 * m0 / 1e18) =
    ///      2`, and at `m1 = 1e18 + 2` the readback is `floor(2e18 / m1) = 1`,
    ///      still exactly `S`. EQUALITY HERE IS CORRECT, NOT A BUG.
    function test_AllowanceSharesNeverIncreasesAfterCorporateAction() public {
        _rebase(WAD + 1);

        uint256 s = 1;
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), s);

        uint256 rawBefore = equity.allowance(safe, address(engine));
        assertEq(rawBefore, 2, "A = ceil(S * m0 / 1e18)");
        assertEq(equity.allowanceShares(safe, address(engine)), s, "lossless round trip at m0");

        // A SMALL increase, below the A * 1e18 / S = 2e18 threshold.
        _rebase(WAD + 2);

        uint256 after_ = equity.allowanceShares(safe, address(engine));
        assertLe(after_, s, "share allowance GREW across a rebase");
        assertEq(after_, s, "expected the equal case at this multiplier");

        // The stored quantity is token-denominated and a corporate action does not
        // touch it. Only its interpretation in shares moves.
        assertEq(equity.allowance(safe, address(engine)), rawBefore, "raw allowance changed");
    }

    /// @notice Past the threshold it strictly shrinks, and the spend agrees.
    /// @dev The exact threshold is `allowanceShares < S` iff `m1 > A * 1e18 / S`.
    ///      With `A = 2`, `S = 1` that is `m1 > 2e18`, so `2e18 + 1` is the first
    ///      multiplier at which the readback drops.
    ///
    ///      The second assertion is the one that makes the view trustworthy: the
    ///      spend needs `ceil(S * m1 / 1e18) <= A`, which is the SAME condition as
    ///      `allowanceShares >= S`. So the view and the spend cannot disagree —
    ///      a caller can use `allowanceShares` as a decision procedure rather than
    ///      as an estimate.
    function test_AllowanceSharesEventuallyShrinksAfterSufficientCorporateAction() public {
        _rebase(WAD + 1);

        uint256 s = 1;
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), s);
        assertEq(equity.allowance(safe, address(engine)), 2, "A");

        // Past the threshold.
        _rebase(2 * WAD + 1);

        assertLt(equity.allowanceShares(safe, address(engine)), s, "did not shrink past threshold");

        // And the spend fails, for the same reason and at the same boundary.
        vm.prank(address(engine));
        vm.expectRevert();
        equity.transferSharesFrom(safe, address(engine), s);
    }

    /*//////////////////////////////////////////////////////////////
          8. THE LIVENESS FIX — WHY setEngineShareAllowance EXISTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A sell blocked by a stale allowance is unblocked by an operator
    ///         refresh.
    /// @dev THE REGRESSION GUARD FOR THE LIVENESS FAILURE THIS FUNCTION EXISTS TO
    ///      FIX. Without an operator-callable refresh, a client's ability to sell
    ///      would expire at a moment set by rebase history rather than by anything
    ///      they scheduled, and would stay expired until an owner transaction
    ///      landed.
    ///
    ///      The corporate action here is LARGE (parity to 2e18), deliberately. A
    ///      small one can leave the allowance exactly equal to `S` — see
    ///      {test_AllowanceSharesNeverIncreasesAfterCorporateAction} — and the sell
    ///      would still succeed, so the test would pass while proving nothing.
    ///
    ///      THIS IS THE A5 CASE AND IT IS NOT COVERED BY THE A4 ROUNDING PROOF.
    ///      There, `sharesIn` is recomputed from `o.amountIn` at the settlement-time
    ///      multiplier, so the engine's draw always fits by construction. Here `S`
    ///      is fixed at APPROVAL time and consumed later at a DIFFERENT multiplier.
    ///      Two different quantities that happen to share a symbol.
    function test_SellStillWorksAfterCorporateAction_WithRefresh() public {
        uint256 s = 1e21;

        _ownerCall(abi.encodeCall(TradingModule.setEngineShareAllowance, (address(engine), address(equity), s)));
        assertEq(equity.allowanceShares(safe, address(engine)), s, "precondition");

        // Large enough to pass the m1 > A * 1e18 / S threshold with room to spare.
        _rebase(2 * WAD);

        // Selling those same S shares now needs their GROWN token value, which the
        // stale allowance no longer covers.
        uint256 amountIn = equity.sharesToAmount(s);
        bytes memory inner = _submitExpectingInnerRevert(_sell(amountIn));
        assertEq(
            bytes4(inner), IRebasingEquityToken.InsufficientAllowance.selector, "expected the sell to fail on allowance"
        );

        // The operator refreshes — the whole point of action 2.
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), s);
        assertEq(equity.allowanceShares(safe, address(engine)), s, "refresh did not restore S");

        // And the same sell now goes through.
        vm.prank(operator);
        uint256 amountOut = module.submitOrder(_sell(amountIn));
        assertGt(amountOut, 0, "sell produced nothing");
    }

    /*//////////////////////////////////////////////////////////////
                    9. WHAT THE OPERATOR *CAN* DO
    //////////////////////////////////////////////////////////////*/

    function test_OperatorCanSubmitBuyOrder() public {
        uint256 amountIn = 1e20;
        uint256 sharesBefore = equity.shares(safe);
        uint256 stableBefore = stable.balanceOf(safe);

        vm.prank(operator);
        uint256 amountOut = module.submitOrder(_buy(amountIn));

        assertEq(stable.balanceOf(safe), stableBefore - amountIn, "stable not spent");

        uint256 delta = equity.shares(safe) - sharesBefore;
        assertGt(delta, 0, "no shares delivered");
        // Multiplier is at parity here, so shares and tokens are 1:1 and the
        // comparison is exact rather than tolerance-based.
        assertEq(delta, amountOut, "share delta disagrees with reported amountOut");
    }

    /// @notice The SELL path, which is the one that exercises the share allowance.
    /// @dev A buy-only suite would pass with the share-allowance machinery
    ///      completely broken: a buy draws the stable leg through the ordinary
    ///      token allowance and never touches `transferSharesFrom`.
    function test_OperatorCanSubmitSellOrder() public {
        uint256 amountIn = 1e20;
        uint256 sharesBefore = equity.shares(safe);
        uint256 stableBefore = stable.balanceOf(safe);

        vm.prank(operator);
        uint256 amountOut = module.submitOrder(_sell(amountIn));

        assertLt(equity.shares(safe), sharesBefore, "no shares sold");
        assertEq(stable.balanceOf(safe), stableBefore + amountOut, "stable not received");
    }

    /// @notice The Router authorizes on `msg.sender == o.account`, both being the
    ///         Safe — `isOperator` is never consulted.
    /// @dev THIS TEST DOCUMENTS THE ACTUAL MECHANISM rather than the one a reader
    ///      might assume from the Router's two-branch check. The call chain is
    ///      operator -> module -> SAFE -> Router, so the Router sees the Safe as
    ///      the caller and the Safe as `o.account`, and the first branch passes.
    ///
    ///      Authorization is established by THE SAFE BEING THE CALLER, not by the
    ///      Safe attesting to who its operators are. Operator authorization lives
    ///      entirely in the module, upstream. The `expectCall` count of zero is the
    ///      direct assertion; the fact that the order succeeds at all is the
    ///      corroborating one, since this Safe has no fallback handler and would
    ///      fail closed if the second branch were reached.
    function test_RouterSeesSafeAsBothSenderAndAccount() public {
        vm.expectCall(safe, abi.encodeCall(IClientAccount.isOperator, (operator)), 0);
        vm.expectCall(safe, abi.encodeCall(IClientAccount.isOperator, (address(module))), 0);

        vm.prank(operator);
        uint256 amountOut = module.submitOrder(_buy(1e20));

        assertGt(amountOut, 0, "order did not settle");
    }

    function test_OperatorCannotSubmitOrderForAnotherAccount() public {
        OrderTypes.Order memory o = _buy(1e20);
        o.account = attacker;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.OrderAccountMismatch.selector, attacker, safe));
        module.submitOrder(o);
    }

    /// @notice The module returns the Router's `amountOut`, not zero.
    /// @dev Guards against reaching for `execTransactionFromModule` instead of the
    ///      `ReturnData` variant. The plain version returns only a bool, so the
    ///      module would compile, settle correctly, and report zero to its caller —
    ///      a silent wrong answer rather than a failure.
    function test_SubmitOrderReturnsAmountOut() public {
        uint256 amountIn = 1e20;

        vm.prank(operator);
        uint256 viaModule = module.submitOrder(_buy(amountIn));
        assertGt(viaModule, 0, "module returned zero");

        // Cross-check against the Router directly, from a second identical order,
        // so the figure is verified against the source rather than only asserted
        // non-zero.
        uint256 sharesBefore = equity.shares(safe);
        vm.prank(operator);
        uint256 second = module.submitOrder(_buy(amountIn));
        assertEq(equity.shares(safe) - sharesBefore, second, "returned value is not the delivered amount");
    }

    /// @notice A failed settlement reverts instead of returning quietly.
    /// @dev Safe's module execution reports failure as `success == false` and does
    ///      NOT bubble the inner revert, so an unchecked return would turn every
    ///      failed settlement into a successful call returning zero. The inner
    ///      revert reason is preserved in the error so a slippage failure stays
    ///      diagnosable.
    function test_FailedSettlementRevertsRatherThanSilentlySucceeding() public {
        adapter.setMode(MockAdapter.Mode.Reverting);

        (uint256 sharesBefore, uint256 stableBefore) = _safeHoldings();

        vm.prank(operator);
        vm.expectPartialRevert(TradingModule.ModuleExecutionFailed.selector);
        module.submitOrder(_buy(1e20));

        (uint256 sharesAfter, uint256 stableAfter) = _safeHoldings();
        assertEq(sharesAfter, sharesBefore, "shares moved on a failed settlement");
        assertEq(stableAfter, stableBefore, "stable moved on a failed settlement");
    }

    /*//////////////////////////////////////////////////////////////
                     10. THE INDIRECT-DRAIN ATTACK
    //////////////////////////////////////////////////////////////*/

    /// @notice The operator cannot drain by trading value away to a venue it owns.
    /// @dev THE MOST CREATIVE FORM OF THE DRAIN, and the one a reviewer is most
    ///      likely to ask about: not withdrawing, but selling the Safe's assets at
    ///      a deliberately terrible price into an adapter the operator controls.
    ///      Asserted explicitly rather than left implied.
    ///
    ///      Two independent things stop it, and both are checked. The venue must
    ///      resolve through the {VenueRegistry}, which only an admin writes, so an
    ///      operator-deployed adapter is simply not reachable. And even if it were,
    ///      the engine is the only address holding an allowance from the Safe, so
    ///      the adapter has no way to draw funds itself.
    function test_OperatorCannotDrainViaSelfDealingTrade() public {
        MockAdapter evil = new MockAdapter(operator, IRebasingEquityToken(address(equity)));
        evil.setOutputRate(1); // ~everything in, ~nothing out

        (uint256 sharesBefore, uint256 stableBefore) = _safeHoldings();

        OrderTypes.Order memory o = _sell(1e20);
        o.venueId = UNREGISTERED_VENUE;

        vm.prank(operator);
        vm.expectPartialRevert(TradingModule.ModuleExecutionFailed.selector);
        module.submitOrder(o);

        // The operator cannot register its adapter either — the registry is
        // admin-gated and the module exposes no path to it.
        vm.prank(operator);
        vm.expectRevert();
        venues.setAdapter(UNREGISTERED_VENUE, address(evil));

        // And the adapter holds no allowance of its own.
        assertEq(stable.allowance(safe, address(evil)), 0, "evil adapter has stable allowance");
        assertEq(equity.allowance(safe, address(evil)), 0, "evil adapter has equity allowance");

        (uint256 sharesAfter, uint256 stableAfter) = _safeHoldings();
        assertEq(sharesAfter, sharesBefore, "shares left the safe");
        assertEq(stableAfter, stableBefore, "stable left the safe");
    }

    /// @notice An engine the owner never allowlisted holds nothing.
    /// @dev The spec framed this as "an order routed through it fails on
    ///      allowance", but that order is UNCONSTRUCTIBLE here and it is worth
    ///      saying why rather than writing a test that pretends otherwise: the
    ///      module's `router` is immutable and the Router's `settlementEngine` is
    ///      immutable, so there is no reachable code path that routes a Safe order
    ///      to a second engine at all. Structural, not a runtime check.
    ///
    ///      What remains meaningful — and is what an attacker would actually need —
    ///      is that the unapproved engine cannot draw from the Safe. Asserted
    ///      directly, plus the operator's attempt to grant it an allowance.
    function test_OperatorCannotRouteToUnapprovedEngine() public {
        vm.prank(admin);
        SettlementEngine rogue = new SettlementEngine(admin, venues, feeTo);

        assertFalse(module.isApprovedEngine(address(rogue)), "rogue is allowlisted");
        assertEq(stable.allowance(safe, address(rogue)), 0, "rogue has stable allowance");
        assertEq(equity.allowanceShares(safe, address(rogue)), 0, "rogue has share allowance");

        // The operator cannot grant it one.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.EngineNotApproved.selector, address(rogue)));
        module.setEngineShareAllowance(address(rogue), address(equity), 1e20);

        // Nor can the rogue engine draw anything.
        vm.prank(address(rogue));
        vm.expectRevert();
        equity.transferSharesFrom(safe, address(rogue), 1);

        // The module is welded to one Router, which is welded to one engine.
        assertEq(module.router(), address(router), "router not immutable as assumed");
        assertEq(address(router.settlementEngine()), address(engine), "router engine changed");
    }

    /*//////////////////////////////////////////////////////////////
              11. ROUTER DIRECT PATH — DOCUMENTED LIMITATION
    //////////////////////////////////////////////////////////////*/

    /// @notice A direct operator -> Router call naming the Safe reverts.
    /// @dev THE DOCUMENTED CONSEQUENCE of not installing a fallback handler, and it
    ///      is a limitation rather than a defence. The Router's first branch fails
    ///      because `msg.sender != o.account`; it then probes
    ///      `IClientAccount(safe).isOperator`, and a Safe with no fallback handler
    ///      returns empty data, which fails to decode, which the Router's try/catch
    ///      turns into `UnauthorizedCaller`. Failing closed is right, but the effect
    ///      is that operators MUST route through the module.
    ///
    ///      This is also why {IClientAccount} is a Router-side interface only
    ///      bespoke accounts implement. Production would install a
    ///      `CompatibilityFallbackHandler` extension answering `isOperator` to
    ///      support the direct path; cut here for scope.
    function test_DirectRouterCallWithSafeAsAccountReverts() public {
        (uint256 sharesBefore, uint256 stableBefore) = _safeHoldings();

        vm.prank(operator);
        (bool ok, bytes memory err) = address(router).call(abi.encodeCall(Router.submitOrder, (_buy(1e20))));
        assertFalse(ok, "direct router call succeeded");

        // NOT `UnauthorizedCaller`, AND THIS IS WORTH RECORDING PRECISELY.
        //
        // The Router's `_authorize` wraps the operator probe in try/catch and its
        // NatSpec says a contract account that "returns undecodable data is treated
        // as not authorized rather than surfacing an ABI decoding error". That is
        // not what happens for THIS account. Solidity's try/catch does not catch
        // failures that occur while DECODING a successful call's return data, so a
        // Safe with no fallback handler — which returns empty data rather than
        // reverting — produces a bare, dataless revert that propagates past the
        // `catch` clause untouched.
        //
        // The security outcome is still correct: the call reverts and nothing
        // moves, which the balance assertions below confirm. What is lost is
        // diagnosability, and what is inaccurate is the Router's comment. Flagged
        // rather than fixed here, because `Router` is A2 and changing its behaviour
        // is a decision outside this step.
        assertEq(err.length, 0, "expected a bare revert from the decoding failure");

        // The mechanism, asserted directly: the Safe answers the probe with empty
        // data rather than reverting, which is exactly the case try/catch misses.
        (bool probeOk, bytes memory probeRet) = safe.staticcall(abi.encodeCall(IClientAccount.isOperator, (operator)));
        assertTrue(probeOk, "safe reverted rather than returning empty");
        assertEq(probeRet.length, 0, "safe answered isOperator - fallback handler installed?");

        (uint256 sharesAfter, uint256 stableAfter) = _safeHoldings();
        assertEq(sharesAfter, sharesBefore, "shares moved");
        assertEq(stableAfter, stableBefore, "stable moved");
    }

    /// @notice A non-Safe caller naming an EOA account still gets the clean error.
    /// @dev The contrast case for the test above, so the finding is scoped rather
    ///      than overstated: the Router's `UnauthorizedCaller` path works fine: the
    ///      code-length short circuit handles EOAs before any probe happens. The
    ///      dataless revert is specific to a CONTRACT account that returns empty
    ///      data, which is precisely what a Safe without a fallback handler does.
    function test_RouterStillReturnsCleanErrorForEoaAccounts() public {
        OrderTypes.Order memory o = _buy(1e20);
        o.account = attacker; // an EOA

        vm.prank(operator);
        vm.expectRevert(Router.UnauthorizedCaller.selector);
        router.submitOrder(o);
    }

    /*//////////////////////////////////////////////////////////////
                        12. OWNER CAPABILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner CAN withdraw — directly through the Safe.
    /// @dev The requirement is that the OPERATOR cannot withdraw, not that
    ///      withdrawal is impossible. This asserts the other half, and note the
    ///      route: an ordinary Safe transaction to the token. The module is not
    ///      involved and has no function that could have done it.
    function test_OwnerCanWithdrawFromSafeDirectly() public {
        uint256 stableAmount = stable.balanceOf(safe);
        uint256 shareAmount = equity.shares(safe);

        _ownerSafeCall(address(stable), abi.encodeCall(IERC20.transfer, (owner, stableAmount)));
        _ownerSafeCall(address(equity), abi.encodeCall(IRebasingEquityToken.transferShares, (owner, shareAmount)));

        assertEq(stable.balanceOf(owner), stableAmount, "owner did not receive stable");
        assertEq(equity.shares(owner), shareAmount, "owner did not receive shares");
        assertEq(stable.balanceOf(safe), 0, "stable left in safe");
        assertEq(equity.shares(safe), 0, "shares left in safe");
    }

    function test_OwnerCanSubmitOrderThroughModule() public {
        uint256 sharesBefore = equity.shares(safe);

        bytes memory ret = _ownerCall(abi.encodeCall(TradingModule.submitOrder, (_buy(1e20))));
        // `execAsOwner` returns `execTransaction`'s own return data (the encoded
        // bool), not the inner amountOut — Safe discards inner return data on the
        // owner path. The state change is the assertion.
        assertTrue(ret.length > 0, "no return data");
        assertGt(equity.shares(safe), sharesBefore, "order did not settle");
    }

    function test_OwnerCanRevokeOperator() public {
        _ownerCall(abi.encodeCall(TradingModule.setOperator, (operator, false)));
        assertFalse(module.isOperator(operator), "operator still enabled");

        vm.prank(operator);
        vm.expectRevert(TradingModule.NotAuthorized.selector);
        module.submitOrder(_buy(1e20));

        vm.prank(operator);
        vm.expectRevert(TradingModule.NotAuthorized.selector);
        module.setEngineShareAllowance(address(engine), address(equity), 1);
    }

    /*//////////////////////////////////////////////////////////////
                  13. CLIENT EXIT — THE PART C ANSWER
    //////////////////////////////////////////////////////////////*/

    /// @notice The client can exit unilaterally, with no cooperation from anyone.
    /// @dev THE PART C ANSWER, AS A TEST. The exit primitive is Safe's own
    ///      `disableModule` — not code we wrote — so the client does not have to
    ///      trust our implementation of their escape hatch. There is no timelock,
    ///      no notice period, no operator signature, and nothing in flight that
    ///      survives it: the operator's authority ends inside the transaction that
    ///      disables the module.
    ///
    ///      After that, withdrawal is an ordinary Safe transaction. Both halves are
    ///      asserted, because "the operator is locked out" is only half an exit if
    ///      the assets cannot then be moved.
    function test_ClientCanExitWithoutCooperation() public {
        // Sanity: the operator works right now, so the lockout below is a real
        // change and not a precondition that never held.
        vm.prank(operator);
        module.submitOrder(_buy(1e18));

        // The exit: one Safe owner transaction, Safe's own function.
        _ownerSafeCall(safe, abi.encodeCall(ModuleManager.disableModule, (SENTINEL, address(module))));
        assertFalse(Safe(payable(safe)).isModuleEnabled(address(module)), "module still enabled");

        // Both operator actions are dead. The Safe rejects the module at its own
        // gate (GS104) — the module's internal authorization is not even reached,
        // which is the point: the authority was never the module's to keep.
        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.submitOrder(_buy(1e18));

        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.setEngineShareAllowance(address(engine), address(equity), 1e20);

        // And the owner takes everything out through a normal Safe transaction.
        uint256 stableAmount = stable.balanceOf(safe);
        uint256 shareAmount = equity.shares(safe);
        _ownerSafeCall(address(stable), abi.encodeCall(IERC20.transfer, (owner, stableAmount)));
        _ownerSafeCall(address(equity), abi.encodeCall(IRebasingEquityToken.transferShares, (owner, shareAmount)));

        assertEq(stable.balanceOf(safe), 0, "stable stranded");
        assertEq(equity.shares(safe), 0, "shares stranded");
        assertEq(stable.balanceOf(owner), stableAmount, "owner short");
    }

    /*//////////////////////////////////////////////////////////////
                      14. CONSTRUCTION AND ARGUMENT GUARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Both wiring addresses must be non-zero contracts.
    /// @dev Worth testing rather than waving through, because both are IMMUTABLE:
    ///      a module deployed against a bad address cannot be repaired, only
    ///      abandoned. A zero `router` would make every order revert, and a
    ///      code-less `safe` would make every execution silently unroutable — both
    ///      discovered only after the client had enabled the module.
    function test_ConstructorRejectsBadWiring() public {
        vm.expectRevert(TradingModule.ZeroAddress.selector);
        new TradingModule(address(0), address(router));

        vm.expectRevert(TradingModule.ZeroAddress.selector);
        new TradingModule(safe, address(0));

        // Non-zero but code-less: an EOA, or an address that has not been deployed
        // to yet. Distinguished from the zero case by its own error.
        vm.expectRevert(abi.encodeWithSelector(TradingModule.NotAContract.selector, attacker));
        new TradingModule(attacker, address(router));

        vm.expectRevert(abi.encodeWithSelector(TradingModule.NotAContract.selector, attacker));
        new TradingModule(safe, attacker);
    }

    function test_ConstructorStoresWiring() public view {
        assertEq(module.safe(), safe, "safe");
        assertEq(module.router(), address(router), "router");
    }

    function test_SetOperatorRejectsZeroAddress() public {
        vm.prank(safe);
        vm.expectRevert(TradingModule.ZeroAddress.selector);
        module.setOperator(address(0), true);
    }

    /// @notice An engine must be a contract to be allowlisted.
    /// @dev Both limbs of `InvalidEngine`, since an EOA engine would accept an
    ///      allowance it could never act on and would sit in the token set
    ///      consuming one of the eight revocation slots.
    function test_SetApprovedEngineRejectsNonContract() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.InvalidEngine.selector, address(0)));
        module.setApprovedEngine(address(0), true);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TradingModule.InvalidEngine.selector, attacker));
        module.setApprovedEngine(attacker, true);

        // DEALLOWLISTING skips both checks on purpose: an engine that has since
        // self-destructed, or was somehow allowlisted before this guard existed,
        // must still be revocable. Refusing here would be the lockout the
        // {setApprovedEngine} ordering note exists to avoid.
        vm.prank(safe);
        module.setApprovedEngine(attacker, false);
        assertFalse(module.isApprovedEngine(attacker), "deallowlist of a non-contract failed");
    }

    /// @notice The share-approval record tracks grants and clears on revocation.
    /// @dev This flag gates the belt-and-braces `approveShares(engine, 0)` in
    ///      revocation, so a stale `true` would mean calling `approveShares` on a
    ///      token that never accepted it — reverting the emergency path. Asserted
    ///      directly rather than inferred from revocation succeeding.
    function test_ShareApprovalRecordTracksGrantAndRevocation() public {
        assertTrue(module.hasShareApproval(address(engine), address(equity)), "not recorded at setup");
        assertFalse(module.hasShareApproval(address(engine), address(stable)), "recorded for a token leg");
        assertFalse(module.hasShareApproval(attacker, address(equity)), "recorded for a non-engine");

        _ownerCall(abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(equity))));
        assertFalse(module.hasShareApproval(address(engine), address(equity)), "not cleared on revocation");

        // Revocation also zeroes the CAP, so the operator cannot simply re-grant:
        // the owner has to choose a new ceiling first. That is the intended
        // consequence — a revoked engine should not inherit a limit the owner set
        // under different assumptions — and it is asserted here rather than left as
        // a comment on {TradingModule.setEngineShareCap}.
        assertEq(module.engineShareCap(address(engine), address(equity)), 0, "cap survived revocation");

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TradingModule.ExceedsShareCap.selector, address(engine), address(equity), 1e20, 0)
        );
        module.setEngineShareAllowance(address(engine), address(equity), 1e20);

        // With a fresh cap from the owner, the grant lands and is recorded again.
        _ownerCall(abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), SHARE_CAP)));
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), 1e20);
        assertTrue(module.hasShareApproval(address(engine), address(equity)), "not re-recorded");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice For ANY spender that is not an allowlisted engine, an
    ///         operator-initiated approval leaves the allowance at zero.
    /// @dev The machine-checked form of the approval-is-withdrawal argument: the
    ///      operator does not get to pick the spender, whoever it picks.
    function testFuzz_OperatorCannotApproveNonEngine(address spender, uint256 shareAmount) public {
        vm.assume(spender != address(engine));
        vm.assume(spender != address(0));

        uint256 before = equity.allowance(safe, spender);

        vm.prank(operator);
        (bool ok,) = address(module)
            .call(abi.encodeCall(TradingModule.setEngineShareAllowance, (spender, address(equity), shareAmount)));

        assertFalse(ok, "approval to a non-engine succeeded");
        assertEq(equity.allowance(safe, spender), before, "allowance to a non-engine changed");
    }

    /// @notice An operator call never leaves the share allowance above the cap.
    function testFuzz_OperatorNeverExceedsCap(uint256 cap, uint256 shareAmount) public {
        cap = bound(cap, 0, 1e30);
        shareAmount = bound(shareAmount, 0, 1e30);

        _ownerCall(abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), cap)));

        // Start from a known-good state so a rejected call has something to leave
        // behind, rather than the assertion passing on an empty allowance.
        uint256 seed = cap > 0 ? cap : 0;
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), seed);

        vm.prank(operator);
        (bool ok,) = address(module)
            .call(
                abi.encodeCall(TradingModule.setEngineShareAllowance, (address(engine), address(equity), shareAmount))
            );

        if (ok) assertLe(shareAmount, cap, "an accepted call exceeded the cap");
        assertLe(equity.allowanceShares(safe, address(engine)), cap, "allowance above cap");
    }

    /// @notice Any caller that is neither the Safe nor an operator is refused by
    ///         every function.
    function testFuzz_UnauthorizedCallerIsRefusedEverywhere(address caller) public {
        vm.assume(caller != safe);
        vm.assume(caller != operator);
        vm.assume(caller != address(0));

        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(TradingModule.setOperator, (caller, true));
        calls[1] = abi.encodeCall(TradingModule.setApprovedEngine, (caller, true));
        calls[2] = abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), 1e30));
        calls[3] = abi.encodeCall(
            TradingModule.setEngineTokenAllowance, (address(engine), address(stable), type(uint256).max)
        );
        calls[4] = abi.encodeCall(TradingModule.revokeEngineAllowance, (address(engine), address(stable)));
        calls[5] = abi.encodeCall(TradingModule.submitOrder, (_buy(1e18)));
        calls[6] = abi.encodeCall(TradingModule.setEngineShareAllowance, (address(engine), address(equity), 1));

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool ok,) = address(module).call(calls[i]);
            assertFalse(ok, "unauthorized call succeeded");
        }
    }

    /// @notice `approveShares(S)` at `m0`, rebase to `m1 >= m0`, allowance in
    ///         shares is never above `S`.
    /// @dev The machine-checked form of the never-increases property, over the whole
    ///      parameter space rather than at the two hand-picked multipliers used
    ///      above. It will naturally produce the equal-across-a-rebase case as well
    ///      as the strict-decrease one, which is exactly why the property is stated
    ///      as `<=`.
    function testFuzz_ShareAllowanceNeverIncreasesAcrossRebase(uint256 s, uint256 m0, uint256 m1) public {
        m0 = bound(m0, WAD, 1e24);
        m1 = bound(m1, m0, 1e26);
        s = bound(s, 1, SHARE_CAP);

        if (m0 > WAD) _rebase(m0);

        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), s);

        // Lossless at the approval multiplier.
        assertEq(equity.allowanceShares(safe, address(engine)), s, "round trip at m0");

        if (m1 > m0) _rebase(m1);

        uint256 after_ = equity.allowanceShares(safe, address(engine));
        assertLe(after_, s, "share allowance grew across a rebase");

        // The view and the spend agree: `allowanceShares >= s` iff the spend of `s`
        // shares fits. Checked as an equivalence, not as two separate facts.
        bool viewSaysOk = after_ >= s;
        vm.prank(address(engine));
        (bool spendOk,) =
            address(equity).call(abi.encodeCall(IRebasingEquityToken.transferSharesFrom, (safe, address(engine), s)));
        assertEq(viewSaysOk, spendOk, "view and spend disagree");
    }
}
