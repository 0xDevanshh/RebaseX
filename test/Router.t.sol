// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Router} from "../src/core/Router.sol";
import {IClientAccount} from "../src/interfaces/IClientAccount.sol";
import {ISettlementEngine} from "../src/interfaces/ISettlementEngine.sol";
import {IVenueAdapter} from "../src/interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {VenueRegistry} from "../src/router/VenueRegistry.sol";

/*//////////////////////////////////////////////////////////////////////////
                                 MOCKS
//////////////////////////////////////////////////////////////////////////*/

/// @dev Records what the Router delegated and returns a configurable amount. It
///      deliberately performs no token movement — this suite tests orchestration,
///      and a mock that moved funds would blur which contract did what.
contract MockSettlementEngine is ISettlementEngine {
    OrderTypes.Order public receivedOrder;
    bytes32 public receivedVenueId;
    address public receivedAdapter;
    uint256 public callCount;

    uint256 public amountOutToReturn;
    bool public shouldRevert;

    // Reentrancy probe.
    Router public router;
    bool public reenterOnSettle;
    OrderTypes.Order private _reentryOrder;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    function setAmountOut(uint256 amount) external {
        amountOutToReturn = amount;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function armReentry(Router router_, OrderTypes.Order calldata order) external {
        router = router_;
        _reentryOrder = order;
        reenterOnSettle = true;
    }

    function disarmReentry() external {
        reenterOnSettle = false;
    }

    function settle(OrderTypes.Order calldata order, bytes32 resolvedVenueId, address adapter)
        external
        returns (uint256)
    {
        if (shouldRevert) revert("settlement failed");

        receivedOrder = order;
        receivedVenueId = resolvedVenueId;
        receivedAdapter = adapter;
        callCount++;

        if (reenterOnSettle) {
            reentryAttempted = true;
            // Attempt to re-enter the Router mid-settlement. Captures the revert
            // data so the test can assert WHY it failed, not merely that it did.
            try router.submitOrder(_reentryOrder) returns (uint256) {
                reentrySucceeded = true;
            } catch (bytes memory data) {
                reentrySucceeded = false;
                reentryRevertData = data;
            }
        }

        return amountOutToReturn;
    }
}

/// @dev Quotes a configurable amount, or reverts on demand.
contract MockVenueAdapter is IVenueAdapter {
    uint256 public quoteToReturn;
    bool public shouldRevertOnQuote;

    constructor(uint256 quote_) {
        quoteToReturn = quote_;
    }

    function setQuote(uint256 quote_) external {
        quoteToReturn = quote_;
    }

    function setShouldRevertOnQuote(bool value) external {
        shouldRevertOnQuote = value;
    }

    function quote(address, address, uint256) external view returns (uint256) {
        if (shouldRevertOnQuote) revert("quote unavailable");
        return quoteToReturn;
    }

    function swap(OrderTypes.Order calldata, address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Client account exposing an operator allowlist.
contract MockClientAccount is IClientAccount {
    mapping(address => bool) private _operators;

    function setOperator(address operator, bool allowed) external {
        _operators[operator] = allowed;
    }

    function isOperator(address operator) external view returns (bool) {
        return _operators[operator];
    }
}

/// @dev A contract that is NOT a client account: it has code, so the Router will
///      probe it, but `isOperator` is absent so the call fails.
contract NonConformingAccount {
    uint256 public unrelated;

    function doSomethingElse() external {
        unrelated++;
    }
}

/// @dev Has an `isOperator` that reverts, exercising the catch branch separately
///      from a missing-function failure.
contract RevertingAccount {
    function isOperator(address) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev Minimal balance holder. The Router never calls this; it exists only so a
///      test can observe that no balance ever lands in the Router.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                                  TESTS
//////////////////////////////////////////////////////////////////////////*/

contract RouterTest is Test {
    Router internal router;
    VenueRegistry internal venues;
    MockSettlementEngine internal engine;

    MockVenueAdapter internal adapterA;
    MockVenueAdapter internal adapterB;
    MockVenueAdapter internal adapterC;

    MockClientAccount internal clientAccount;
    MockToken internal tokenIn;
    MockToken internal tokenOut;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant VENUE_A = keccak256("VENUE_A");
    bytes32 internal constant VENUE_B = keccak256("VENUE_B");
    bytes32 internal constant VENUE_C = keccak256("VENUE_C");
    bytes32 internal constant BEST_EXECUTION = bytes32(0);

    uint256 internal constant SETTLED_AMOUNT = 12_345;

    function setUp() public {
        venues = new VenueRegistry(admin);
        engine = new MockSettlementEngine();
        router = new Router(venues, ISettlementEngine(address(engine)));

        adapterA = new MockVenueAdapter(90);
        adapterB = new MockVenueAdapter(110);
        adapterC = new MockVenueAdapter(100);

        clientAccount = new MockClientAccount();
        tokenIn = new MockToken();
        tokenOut = new MockToken();

        engine.setAmountOut(SETTLED_AMOUNT);

        // Deadlines are absolute timestamps; move off genesis so `block.timestamp`
        // arithmetic in tests is realistic.
        vm.warp(1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _order(address account, bytes32 venueId) internal view returns (OrderTypes.Order memory) {
        return OrderTypes.Order({
            account: account,
            assetIn: address(tokenIn),
            assetOut: address(tokenOut),
            amountIn: 1000,
            minAmountOut: 900,
            venueId: venueId,
            deadline: block.timestamp + 1 hours
        });
    }

    function _registerVenue(bytes32 venueId, address adapter) internal {
        vm.prank(admin);
        venues.setAdapter(venueId, adapter);
    }

    function _hash(OrderTypes.Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsImmutableDependencies() public view {
        assertEq(address(router.venueRegistry()), address(venues));
        assertEq(address(router.settlementEngine()), address(engine));
        assertEq(router.MAX_VENUES_SCANNED(), 16);
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(Router.ZeroAddress.selector);
        new Router(VenueRegistry(address(0)), ISettlementEngine(address(engine)));
    }

    function test_constructor_revertsOnZeroSettlementEngine() public {
        vm.expectRevert(Router.ZeroAddress.selector);
        new Router(venues, ISettlementEngine(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                    HAPPY PATH: OWN ACCOUNT, EXPLICIT VENUE
    //////////////////////////////////////////////////////////////*/

    function test_submitOrder_ownAccountExplicitVenue() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        uint256 amountOut = router.submitOrder(o);

        assertEq(amountOut, SETTLED_AMOUNT, "returned amountOut");
        assertEq(engine.callCount(), 1, "settlement should be called exactly once");
        assertEq(engine.receivedVenueId(), VENUE_A, "resolvedVenueId");
        assertEq(engine.receivedAdapter(), address(adapterA), "adapter");
    }

    /// @notice The engine must receive the order unmodified, field for field.
    function test_submitOrder_deliversExactOrderToSettlement() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        router.submitOrder(o);

        (
            address account,
            address assetIn,
            address assetOut,
            uint256 amountIn,
            uint256 minAmountOut,
            bytes32 venueId,
            uint256 deadline
        ) = engine.receivedOrder();

        assertEq(account, o.account, "account");
        assertEq(assetIn, o.assetIn, "assetIn");
        assertEq(assetOut, o.assetOut, "assetOut");
        assertEq(amountIn, o.amountIn, "amountIn");
        assertEq(minAmountOut, o.minAmountOut, "minAmountOut");
        assertEq(venueId, o.venueId, "venueId");
        assertEq(deadline, o.deadline, "deadline");
    }

    /// @dev For an explicit venue, `order.venueId == resolvedVenueId`.
    function test_submitOrder_explicitVenueMatchesResolvedVenue() public {
        _registerVenue(VENUE_B, address(adapterB));
        OrderTypes.Order memory o = _order(alice, VENUE_B);

        vm.prank(alice);
        router.submitOrder(o);

        (,,,,, bytes32 submittedVenueId,) = engine.receivedOrder();
        assertEq(submittedVenueId, engine.receivedVenueId(), "explicit venue should be unchanged");
    }

    /// @dev Registering several venues must not confuse explicit resolution.
    function test_submitOrder_explicitVenuePicksCorrectAdapterAmongMany() public {
        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));
        _registerVenue(VENUE_C, address(adapterC));

        OrderTypes.Order memory o = _order(alice, VENUE_C);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedAdapter(), address(adapterC), "should resolve VENUE_C's adapter");
        assertEq(engine.receivedVenueId(), VENUE_C);
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY PATH: OPERATOR
    //////////////////////////////////////////////////////////////*/

    function test_submitOrder_authorizedOperator() public {
        _registerVenue(VENUE_A, address(adapterA));
        clientAccount.setOperator(operator, true);

        OrderTypes.Order memory o = _order(address(clientAccount), VENUE_A);

        vm.prank(operator);
        uint256 amountOut = router.submitOrder(o);

        assertEq(amountOut, SETTLED_AMOUNT);
        assertEq(engine.callCount(), 1);
    }

    /// @notice The submitter is recorded separately from the account, so operator
    ///         activity is attributable off-chain.
    function test_event_operatorSubmitterDiffersFromAccount() public {
        _registerVenue(VENUE_A, address(adapterA));
        clientAccount.setOperator(operator, true);

        OrderTypes.Order memory o = _order(address(clientAccount), VENUE_A);

        vm.expectEmit(true, true, true, true, address(router));
        emit Router.OrderSubmitted(
            _hash(o),
            address(clientAccount), // account
            operator, // submitter -- deliberately different
            o.assetIn,
            o.assetOut,
            o.amountIn,
            o.minAmountOut,
            o.venueId,
            o.deadline
        );

        vm.prank(operator);
        router.submitOrder(o);
    }

    /// @dev A client account may also submit for itself.
    function test_submitOrder_clientAccountSubmitsForItself() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(address(clientAccount), VENUE_A);

        vm.prank(address(clientAccount));
        router.submitOrder(o);

        assertEq(engine.callCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY PATH: BEST EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice A=90, B=110, C=100 -> B must win.
    function test_bestExecution_selectsHighestQuote() public {
        _registerVenue(VENUE_A, address(adapterA)); // 90
        _registerVenue(VENUE_B, address(adapterB)); // 110
        _registerVenue(VENUE_C, address(adapterC)); // 100

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedVenueId(), VENUE_B, "should choose VENUE_B");
        assertEq(engine.receivedAdapter(), address(adapterB), "should choose adapterB");
    }

    function test_event_bestExecutionReportsSubmittedZeroAndConcreteResolved() public {
        _registerVenue(VENUE_A, address(adapterA)); // 90
        _registerVenue(VENUE_B, address(adapterB)); // 110

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.expectEmit(true, true, true, true, address(router));
        emit Router.OrderRouted(_hash(o), VENUE_B, address(adapterB), 110, SETTLED_AMOUNT);

        vm.prank(alice);
        router.submitOrder(o);

        // The submitted order carried venueId == 0; the resolved venue is concrete.
        (,,,,, bytes32 submittedVenueId,) = engine.receivedOrder();
        assertEq(submittedVenueId, bytes32(0), "submitted venueId should stay zero");
        assertEq(engine.receivedVenueId(), VENUE_B, "resolved venueId should be concrete");
    }

    /// @notice A reverting quote must be skipped, not abort the whole order.
    ///         A=revert, B=100, C=120 -> C must win.
    function test_bestExecution_skipsRevertingAdapter() public {
        adapterA.setShouldRevertOnQuote(true);
        adapterB.setQuote(100);
        adapterC.setQuote(120);

        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));
        _registerVenue(VENUE_C, address(adapterC));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedVenueId(), VENUE_C, "should choose VENUE_C");
        assertEq(engine.receivedAdapter(), address(adapterC));
    }

    /// @dev A zero quote is treated the same as no quote: skipped.
    function test_bestExecution_skipsZeroQuote() public {
        adapterA.setQuote(0);
        adapterB.setQuote(50);

        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedVenueId(), VENUE_B);
    }

    /// @dev First venue winning exercises the "no later candidate beats it" path.
    function test_bestExecution_firstVenueWins() public {
        adapterA.setQuote(500);
        adapterB.setQuote(10);

        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedVenueId(), VENUE_A);
    }

    /// @dev Ties keep the first venue seen: selection is strictly-greater.
    function test_bestExecution_tieKeepsFirstSeen() public {
        adapterA.setQuote(100);
        adapterB.setQuote(100);

        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(venues.venueIdAt(0), VENUE_A, "precondition: A enumerated first");
        assertEq(engine.receivedVenueId(), VENUE_A, "tie should not displace the incumbent");
    }

    function test_bestExecution_singleVenue() public {
        _registerVenue(VENUE_A, address(adapterA));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedVenueId(), VENUE_A);
    }

    /// @dev Exactly at the cap must succeed; the cap is inclusive.
    function test_bestExecution_atMaxVenuesScannedSucceeds() public {
        for (uint256 i; i < 16; ++i) {
            MockVenueAdapter a = new MockVenueAdapter(i + 1);
            _registerVenue(keccak256(abi.encode("V", i)), address(a));
        }
        assertEq(venues.venueCount(), 16);

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        router.submitOrder(o);

        // The last registered adapter quoted highest (16).
        assertEq(engine.receivedVenueId(), keccak256(abi.encode("V", uint256(15))));
    }

    /*//////////////////////////////////////////////////////////////
                        NEGATIVE: AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice THE LOAD-BEARING AUTHORIZATION TEST. Without this check a stranger
    ///         could submit orders against another account's standing allowance.
    function test_revert_unauthorizedCallerForContractAccount() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(address(clientAccount), VENUE_A);

        vm.prank(stranger);
        vm.expectRevert(Router.UnauthorizedCaller.selector);
        router.submitOrder(o);

        assertEq(engine.callCount(), 0, "settlement must not be reached");
    }

    /// @dev An EOA account can only authorize itself; it has no code to express an
    ///      operator relationship.
    function test_revert_unauthorizedCallerForEoaAccount() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A); // alice is an EOA

        vm.prank(stranger);
        vm.expectRevert(Router.UnauthorizedCaller.selector);
        router.submitOrder(o);
    }

    /// @dev A revoked operator loses access.
    function test_revert_operatorRevoked() public {
        _registerVenue(VENUE_A, address(adapterA));
        clientAccount.setOperator(operator, true);
        clientAccount.setOperator(operator, false);

        OrderTypes.Order memory o = _order(address(clientAccount), VENUE_A);

        vm.prank(operator);
        vm.expectRevert(Router.UnauthorizedCaller.selector);
        router.submitOrder(o);
    }

    /// @dev A contract without `isOperator` must produce a clean
    ///      UnauthorizedCaller, not a low-level decoding failure.
    function test_revert_nonConformingContractAccount() public {
        _registerVenue(VENUE_A, address(adapterA));
        NonConformingAccount bogus = new NonConformingAccount();

        OrderTypes.Order memory o = _order(address(bogus), VENUE_A);

        vm.prank(stranger);
        vm.expectRevert(Router.UnauthorizedCaller.selector);
        router.submitOrder(o);
    }

    /// @dev An account whose `isOperator` reverts is treated as unauthorized.
    function test_revert_accountWithRevertingIsOperator() public {
        _registerVenue(VENUE_A, address(adapterA));
        RevertingAccount bogus = new RevertingAccount();

        OrderTypes.Order memory o = _order(address(bogus), VENUE_A);

        vm.prank(stranger);
        vm.expectRevert(Router.UnauthorizedCaller.selector);
        router.submitOrder(o);
    }

    function test_revert_zeroAccount() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(address(0), VENUE_A);

        vm.prank(stranger);
        vm.expectRevert(Router.ZeroAddress.selector);
        router.submitOrder(o);
    }

    /*//////////////////////////////////////////////////////////////
                        NEGATIVE: ORDER VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_revert_deadlineExpired() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.deadline = block.timestamp - 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Router.DeadlineExpired.selector, block.timestamp - 1, block.timestamp));
        router.submitOrder(o);
    }

    /// @dev The order expires AFTER its deadline, not on it.
    function test_deadlineAtCurrentTimestampIsValid() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.deadline = block.timestamp;

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.callCount(), 1);
    }

    function test_revert_zeroAmountIn() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.amountIn = 0;

        vm.prank(alice);
        vm.expectRevert(Router.ZeroAmount.selector);
        router.submitOrder(o);
    }

    /// @notice POLICY: a zero minimum output is unlimited slippage and is refused.
    function test_revert_zeroMinAmountOut() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.minAmountOut = 0;

        vm.prank(alice);
        vm.expectRevert(Router.ZeroMinAmountOut.selector);
        router.submitOrder(o);
    }

    function test_revert_zeroAssetIn() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.assetIn = address(0);

        vm.prank(alice);
        vm.expectRevert(Router.ZeroAddress.selector);
        router.submitOrder(o);
    }

    function test_revert_zeroAssetOut() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.assetOut = address(0);

        vm.prank(alice);
        vm.expectRevert(Router.ZeroAddress.selector);
        router.submitOrder(o);
    }

    function test_revert_identicalAssets() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);
        o.assetOut = o.assetIn;

        vm.prank(alice);
        vm.expectRevert(Router.IdenticalAssets.selector);
        router.submitOrder(o);
    }

    /*//////////////////////////////////////////////////////////////
                        NEGATIVE: VENUE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev The Router reuses VenueRegistry's error rather than defining its own.
    function test_revert_unknownExplicitVenue() public {
        OrderTypes.Order memory o = _order(alice, VENUE_A); // never registered

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, VENUE_A));
        router.submitOrder(o);
    }

    function test_revert_bestExecutionWithNoVenues() public {
        assertEq(venues.venueCount(), 0, "precondition");
        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        vm.expectRevert(Router.NoVenueAvailable.selector);
        router.submitOrder(o);
    }

    function test_revert_bestExecutionAllQuotesZero() public {
        adapterA.setQuote(0);
        adapterB.setQuote(0);
        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        vm.expectRevert(Router.NoVenueAvailable.selector);
        router.submitOrder(o);
    }

    function test_revert_bestExecutionAllQuotesRevert() public {
        adapterA.setShouldRevertOnQuote(true);
        adapterB.setShouldRevertOnQuote(true);
        _registerVenue(VENUE_A, address(adapterA));
        _registerVenue(VENUE_B, address(adapterB));

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        vm.expectRevert(Router.NoVenueAvailable.selector);
        router.submitOrder(o);
    }

    function test_revert_tooManyVenues() public {
        for (uint256 i; i < 17; ++i) {
            MockVenueAdapter a = new MockVenueAdapter(1);
            _registerVenue(keccak256(abi.encode("V", i)), address(a));
        }
        assertEq(venues.venueCount(), 17);

        OrderTypes.Order memory o = _order(alice, BEST_EXECUTION);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Router.TooManyVenues.selector, 17, 16));
        router.submitOrder(o);
    }

    /// @dev An over-full registry does NOT block explicit routing -- only best
    ///      execution scans, so only best execution is capped.
    function test_tooManyVenuesStillAllowsExplicitRouting() public {
        for (uint256 i; i < 17; ++i) {
            MockVenueAdapter a = new MockVenueAdapter(1);
            _registerVenue(keccak256(abi.encode("V", i)), address(a));
        }
        _registerVenue(VENUE_A, address(adapterA));

        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.receivedVenueId(), VENUE_A);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT FAILURE
    //////////////////////////////////////////////////////////////*/

    /// @notice A failed settlement reverts the entire transaction, so no Router
    ///         log survives -- including the OrderSubmitted emitted beforehand.
    function test_revert_settlementFailurePropagates() public {
        _registerVenue(VENUE_A, address(adapterA));
        engine.setShouldRevert(true);

        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        vm.expectRevert(bytes("settlement failed"));
        router.submitOrder(o);
    }

    /// @notice A failed settlement rolls back every effect of the call.
    /// @dev NOT asserted here: that the `OrderSubmitted` log is discarded. That is
    ///      an EVM guarantee — a reverted frame commits no logs — but it is not
    ///      observable from a test, because `vm.recordLogs` collects logs at the
    ///      point they are EMITTED, including from frames that subsequently revert.
    ///      Asserting on it would look like a proof while testing the cheatcode
    ///      rather than the chain.
    ///
    ///      What IS observable, and what this asserts, is that no state survived:
    ///      settlement recorded nothing, so the whole orchestration was undone.
    function test_failedSettlementRollsBackAllEffects() public {
        _registerVenue(VENUE_A, address(adapterA));
        engine.setShouldRevert(true);

        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        try router.submitOrder(o) {
            fail();
        } catch {}

        assertEq(engine.callCount(), 0, "no settlement should be recorded");
        assertEq(engine.receivedVenueId(), bytes32(0), "no venue should be recorded");
        assertEq(engine.receivedAdapter(), address(0), "no adapter should be recorded");
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// @notice The settlement engine attempts to re-enter `submitOrder` from inside
    ///         `settle`. The nested call must be rejected by `nonReentrant`.
    ///
    ///         The reentry order is deliberately VALID and self-authorized (its
    ///         account is the engine itself), so the guard is the only possible
    ///         reason for failure -- proven by `test_reentryOrderIsValidStandalone`
    ///         below, which submits the identical order successfully once the
    ///         reentry probe is disarmed.
    function test_reentrancy_nestedSubmitOrderIsRejected() public {
        _registerVenue(VENUE_A, address(adapterA));

        OrderTypes.Order memory reentryOrder = _order(address(engine), VENUE_A);
        engine.armReentry(router, reentryOrder);

        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        router.submitOrder(o);

        assertTrue(engine.reentryAttempted(), "the mock must actually have tried to re-enter");
        assertFalse(engine.reentrySucceeded(), "nested submitOrder must not succeed");

        bytes memory data = engine.reentryRevertData();
        assertEq(data.length, 4, "expected a 4-byte custom error selector");
        assertEq(
            bytes4(data),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "nested call should fail on the reentrancy guard specifically"
        );
    }

    /// @dev Proves the reentry order above was rejected by the guard and not
    ///      because the order itself was invalid.
    function test_reentryOrderIsValidStandalone() public {
        _registerVenue(VENUE_A, address(adapterA));

        OrderTypes.Order memory reentryOrder = _order(address(engine), VENUE_A);

        vm.prank(address(engine));
        uint256 amountOut = router.submitOrder(reentryOrder);

        assertEq(amountOut, SETTLED_AMOUNT, "the same order succeeds when not nested");
        assertEq(engine.callCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_event_orderSubmittedCarriesEveryField() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.expectEmit(true, true, true, true, address(router));
        emit Router.OrderSubmitted(
            _hash(o), o.account, alice, o.assetIn, o.assetOut, o.amountIn, o.minAmountOut, o.venueId, o.deadline
        );

        vm.prank(alice);
        router.submitOrder(o);
    }

    /// @dev Explicit routing reports indicativeQuote == 0, since no quote is taken.
    function test_event_orderRoutedExplicitVenueHasZeroQuote() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.expectEmit(true, true, true, true, address(router));
        emit Router.OrderRouted(_hash(o), VENUE_A, address(adapterA), 0, SETTLED_AMOUNT);

        vm.prank(alice);
        router.submitOrder(o);
    }

    /// @dev Both events must share the same orderHash so logs can be correlated.
    function test_event_bothEventsShareOrderHash() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.recordLogs();
        vm.prank(alice);
        router.submitOrder(o);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "expected OrderSubmitted and OrderRouted");
        assertEq(logs[0].topics[1], logs[1].topics[1], "orderHash should match across both events");
        assertEq(logs[0].topics[1], _hash(o), "orderHash should be keccak256(abi.encode(order))");
    }

    /*//////////////////////////////////////////////////////////////
                    STATELESSNESS / NO CUSTODY
    //////////////////////////////////////////////////////////////*/

    /// @notice Orchestration must not route value through the Router.
    /// @dev What this proves: the delegation genuinely happened (the engine recorded
    ///      the call) AND no balance landed in the Router. Asserting a zero balance
    ///      alone would be worthless -- it is only meaningful paired with evidence
    ///      that the flow actually ran.
    ///
    ///      The stronger proof is structural rather than assertable: the Router
    ///      contains no `transfer`, `transferFrom`, or `approve` call, and its only
    ///      storage is two immutable addresses plus the reentrancy flag. That is
    ///      what makes custody impossible, not this test.
    function test_noCustody_routerHoldsNoBalanceAfterOrchestration() public {
        _registerVenue(VENUE_A, address(adapterA));

        tokenIn.mint(alice, 1_000_000);
        assertEq(tokenIn.balanceOf(address(router)), 0, "precondition");

        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.callCount(), 1, "delegation must actually have occurred");
        assertEq(tokenIn.balanceOf(address(router)), 0, "assetIn must not reach the Router");
        assertEq(tokenOut.balanceOf(address(router)), 0, "assetOut must not reach the Router");
        assertEq(address(router).balance, 0, "no native balance either");
        assertEq(tokenIn.balanceOf(alice), 1_000_000, "client funds untouched by orchestration");
    }

    /// @notice The Router keeps no record of past orders, so an identical order can
    ///         be submitted again. Documented limitation: replay protection via
    ///         nonces or signatures is out of scope for A2.
    function test_statelessness_identicalOrderCanBeSubmittedTwice() public {
        _registerVenue(VENUE_A, address(adapterA));
        OrderTypes.Order memory o = _order(alice, VENUE_A);

        vm.prank(alice);
        router.submitOrder(o);

        vm.prank(alice);
        router.submitOrder(o);

        assertEq(engine.callCount(), 2, "the same order settles twice -- no replay protection");
    }
}
