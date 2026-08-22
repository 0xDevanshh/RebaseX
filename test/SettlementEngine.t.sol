// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Router} from "../src/core/Router.sol";
import {SettlementEngine} from "../src/core/SettlementEngine.sol";
import {IRebasingEquityToken} from "../src/interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {MockStable} from "../src/mocks/MockStable.sol";
import {VenueRegistry} from "../src/router/VenueRegistry.sol";

import {
    MisbehavingStable,
    MockAdapter,
    MockZeroMultiplierToken,
    ReentrantRouterAdapter,
    ShortTransferEquity
} from "./mocks/SettlementMocks.sol";

/// @title SettlementEngineTest
/// @notice Unit and fuzz coverage for {SettlementEngine}.
/// @dev EVERY SETTLEMENT TEST ENDS WITH A DELTA-BASED CUSTODY ASSERTION. See
///      {_assertCustodyUnchanged}: absolute-zero assertions would be WRONG here,
///      because the engine and the adapter may legitimately hold donated funds
///      that no settlement is allowed to touch — the donation-griefing tests
///      below exist precisely to pin that down.
contract SettlementEngineTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal admin = makeAddr("admin");
    address internal client = makeAddr("client");
    address internal feeTo = makeAddr("feeTo");
    address internal sink = makeAddr("sink");
    address internal stranger = makeAddr("stranger");
    address internal donor = makeAddr("donor");

    /*//////////////////////////////////////////////////////////////
                                 SYSTEM
    //////////////////////////////////////////////////////////////*/

    MockStable internal stable;
    MockStable internal stableB;
    MockShareRegistry internal shareRegistry;
    MockRebasingEquityToken internal equity;
    MockRebasingEquityToken internal equityB;
    VenueRegistry internal venues;
    SettlementEngine internal engine;
    Router internal router;
    MockAdapter internal adapter;

    bytes32 internal constant VENUE = keccak256("MOCK_VENUE");
    uint256 internal constant WAD = 1e18;

    /// @dev keccak of the {SettlementEngine.Settled} signature. Written out rather
    ///      than derived so a field-order change in the event breaks these tests
    ///      loudly instead of silently decoding into the wrong slots.
    bytes32 internal constant SETTLED_TOPIC = keccak256(
        "Settled(bytes32,address,bytes32,address,bool,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant ORDER_SUBMITTED_TOPIC =
        keccak256("OrderSubmitted(bytes32,address,address,address,address,uint256,uint256,bytes32,uint256)");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    struct SettledLog {
        bytes32 orderHash;
        address account;
        bytes32 venueId;
        address rebasingToken;
        bool isBuy;
        address assetIn;
        address assetOut;
        uint256 sharesIn;
        uint256 sharesOutNet;
        uint256 feeShares;
        uint256 multiplierAtSettlement;
        uint256 amountInExecuted;
        uint256 amountOutNet;
        uint256 feeAmount;
    }

    struct Custody {
        uint256 engineIn;
        uint256 engineOut;
        uint256 engineShares;
        uint256 adapterIn;
        uint256 adapterInShares;
    }

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        stable = new MockStable("Stable", "USD", 18);
        stableB = new MockStable("StableB", "USDB", 18);

        vm.startPrank(admin);
        shareRegistry = new MockShareRegistry(admin);

        equity = new MockRebasingEquityToken("Equity", "EQ", admin, IShareRegistry(address(shareRegistry)));
        equityB = new MockRebasingEquityToken("EquityB", "EQB", admin, IShareRegistry(address(shareRegistry)));
        shareRegistry.registerToken(address(equity));
        shareRegistry.registerToken(address(equityB));
        shareRegistry.setCustodiedShares(address(equity), 1e33);
        shareRegistry.setCustodiedShares(address(equityB), 1e33);

        equity.grantRole(equity.PRIMARY_ROLE(), admin);
        equity.grantRole(equity.CORPORATE_ACTION_ROLE(), admin);
        equityB.grantRole(equityB.PRIMARY_ROLE(), admin);

        venues = new VenueRegistry(admin);
        engine = new SettlementEngine(admin, venues, feeTo);
        router = new Router(venues, engine);
        engine.initializeRouter(address(router));
        engine.registerRebasingToken(address(equity), true);

        adapter = new MockAdapter(sink, IRebasingEquityToken(address(equity)));
        venues.setAdapter(VENUE, address(adapter));

        // The rebase-attacker mode needs the authority it is attacking with.
        equity.grantRole(equity.CORPORATE_ACTION_ROLE(), address(adapter));

        equity.mint(address(adapter), 1e26);
        equity.mint(client, 1e24);
        vm.stopPrank();

        stable.mint(address(adapter), 1e30);
        stable.mint(client, 1e26);
        stableB.mint(client, 1e26);

        vm.startPrank(client);
        stable.approve(address(engine), type(uint256).max);
        stableB.approve(address(engine), type(uint256).max);
        equity.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _order(address assetIn, address assetOut, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (OrderTypes.Order memory)
    {
        return OrderTypes.Order({
            account: client,
            assetIn: assetIn,
            assetOut: assetOut,
            amountIn: amountIn,
            minAmountOut: minOut,
            venueId: VENUE,
            deadline: block.timestamp + 1 hours
        });
    }

    function _buy(uint256 amountIn, uint256 minOut) internal view returns (OrderTypes.Order memory) {
        return _order(address(stable), address(equity), amountIn, minOut);
    }

    function _sell(uint256 amountIn, uint256 minOut) internal view returns (OrderTypes.Order memory) {
        return _order(address(equity), address(stable), amountIn, minOut);
    }

    function _submit(OrderTypes.Order memory o) internal returns (uint256) {
        vm.prank(client);
        return router.submitOrder(o);
    }

    function _rebase(uint256 newMultiplier) internal {
        vm.prank(admin);
        equity.applyCorporateAction(newMultiplier);
    }

    function _snapshot(address assetIn, address assetOut) internal view returns (Custody memory c) {
        c.engineIn = IERC20(assetIn).balanceOf(address(engine));
        c.engineOut = IERC20(assetOut).balanceOf(address(engine));
        c.engineShares = equity.shares(address(engine));
        c.adapterIn = IERC20(assetIn).balanceOf(address(adapter));
        c.adapterInShares = equity.shares(address(adapter));
    }

    /// @dev THE CUSTODY POST-CONDITION, delta-based on every axis.
    ///      `isSell` selects a one wei-share tolerance on the adapter's input
    ///      holding: the adapter spends in TOKEN terms while this reads SHARES, and
    ///      floored conversions do not compose under subtraction, so a correct
    ///      adapter can legitimately land one wei-share either side of its
    ///      snapshot. Everything else is exact.
    function _assertCustodyUnchanged(Custody memory before, address assetIn, address assetOut, bool isSell)
        internal
        view
    {
        assertEq(IERC20(assetIn).balanceOf(address(engine)), before.engineIn, "engine assetIn delta");
        assertEq(IERC20(assetOut).balanceOf(address(engine)), before.engineOut, "engine assetOut delta");
        assertEq(equity.shares(address(engine)), before.engineShares, "engine share delta");

        if (isSell) {
            uint256 nowShares = equity.shares(address(adapter));
            uint256 drift = nowShares > before.adapterInShares
                ? nowShares - before.adapterInShares
                : before.adapterInShares - nowShares;
            assertLe(drift, 1, "adapter share drift exceeds one wei-share");
        } else {
            assertEq(IERC20(assetIn).balanceOf(address(adapter)), before.adapterIn, "adapter assetIn delta");
        }

        // The client approves the ENGINE only. No adapter is ever approved on the
        // client's behalf, so this must be zero at all times.
        assertEq(IERC20(assetIn).allowance(client, address(adapter)), 0, "client approved the adapter");
        assertEq(IERC20(assetOut).allowance(client, address(adapter)), 0, "client approved the adapter");
    }

    function _lastSettled(Vm.Log[] memory entries) internal pure returns (SettledLog memory s) {
        uint256 idx = type(uint256).max;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == SETTLED_TOPIC) idx = i;
        }
        require(idx != type(uint256).max, "no Settled event");

        s.orderHash = entries[idx].topics[1];
        s.account = address(uint160(uint256(entries[idx].topics[2])));
        s.venueId = entries[idx].topics[3];

        // Read the data section word by word rather than with a single
        // `abi.decode` of 11 values: that form is stack-too-deep without via-IR.
        // Every field of Settled is a static type, so the encoding is head-only
        // and word N is field N.
        bytes memory d = entries[idx].data;
        s.rebasingToken = address(uint160(_word(d, 0)));
        s.isBuy = _word(d, 1) != 0;
        s.assetIn = address(uint160(_word(d, 2)));
        s.assetOut = address(uint160(_word(d, 3)));
        s.sharesIn = _word(d, 4);
        s.sharesOutNet = _word(d, 5);
        s.feeShares = _word(d, 6);
        s.multiplierAtSettlement = _word(d, 7);
        s.amountInExecuted = _word(d, 8);
        s.amountOutNet = _word(d, 9);
        s.feeAmount = _word(d, 10);
    }

    function _word(bytes memory data, uint256 index) private pure returns (uint256 v) {
        require(data.length >= (index + 1) * 32, "Settled data too short");
        assembly {
            v := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    function _settledFor(OrderTypes.Order memory o) internal returns (SettledLog memory) {
        vm.recordLogs();
        _submit(o);
        return _lastSettled(vm.getRecordedLogs());
    }

    /*//////////////////////////////////////////////////////////////
                    DEPLOYMENT — THE CIRCULAR DEPENDENCY
    //////////////////////////////////////////////////////////////*/

    function test_Deployment_EngineThenRouterThenInitialize() public {
        vm.startPrank(admin);
        SettlementEngine e = new SettlementEngine(admin, venues, feeTo);
        assertEq(e.router(), address(0), "router unset before initialization");

        Router r = new Router(venues, e);
        assertEq(address(r.settlementEngine()), address(e), "router points at engine");

        e.initializeRouter(address(r));
        vm.stopPrank();

        assertEq(e.router(), address(r), "engine points back at router");
    }

    function test_SettleBeforeInitialize_RevertsRouterNotInitialized() public {
        vm.prank(admin);
        SettlementEngine e = new SettlementEngine(admin, venues, feeTo);

        // Distinguishable from an ordinary auth rejection: an uninitialized engine
        // must not present as "the caller is not the router".
        vm.expectRevert(SettlementEngine.RouterNotInitialized.selector);
        e.settle(_buy(1e18, 1), VENUE, address(adapter));
    }

    function test_InitializeRouterTwice_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.RouterAlreadyInitialized.selector, address(router)));
        engine.initializeRouter(address(router));
    }

    function test_InitializeRouterWithEOA_RevertsInvalidRouter() public {
        vm.prank(admin);
        SettlementEngine e = new SettlementEngine(admin, venues, feeTo);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidRouter.selector, stranger));
        e.initializeRouter(stranger);
    }

    function test_InitializeRouterWithZero_RevertsZeroAddress() public {
        vm.prank(admin);
        SettlementEngine e = new SettlementEngine(admin, venues, feeTo);

        vm.prank(admin);
        vm.expectRevert(SettlementEngine.ZeroAddress.selector);
        e.initializeRouter(address(0));
    }

    function test_InitializeRouterFromNonAdmin_Reverts() public {
        vm.prank(admin);
        SettlementEngine e = new SettlementEngine(admin, venues, feeTo);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        e.initializeRouter(address(router));
    }

    /*//////////////////////////////////////////////////////////////
                            HAPPY PATH — BUY
    //////////////////////////////////////////////////////////////*/

    function test_Buy_ClientReceivesNetSharesFeeRecipientReceivesFeeShares() public {
        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 feeShares = (grossShares * engine.FEE_BPS()) / engine.BPS_DENOMINATOR();
        uint256 netShares = grossShares - feeShares;

        Custody memory before = _snapshot(address(stable), address(equity));
        uint256 clientSharesBefore = equity.shares(client);

        SettledLog memory s = _settledFor(_buy(amountIn, 1));

        assertEq(equity.shares(client) - clientSharesBefore, netShares, "client net shares");
        assertEq(equity.shares(feeTo), feeShares, "fee recipient shares");
        assertGt(feeShares, 0, "fee must be non-zero at this size");
        assertEq(feeShares + netShares, grossShares, "feeShares + netShares == grossShares");

        assertEq(s.sharesIn, 0, "sharesIn is 0 on a buy");
        assertEq(s.sharesOutNet, netShares, "sharesOutNet");
        assertEq(s.feeShares, feeShares, "feeShares");
        assertEq(s.multiplierAtSettlement, equity.multiplier(), "multiplierAtSettlement");
        assertEq(s.amountOutNet, equity.sharesToAmount(netShares), "amountOutNet derived from netShares");
        assertEq(s.amountInExecuted, amountIn, "buy executes the full requested input");
        assertTrue(s.isBuy, "isBuy");
        assertEq(s.rebasingToken, address(equity), "rebasingToken");

        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_Buy_AtNonUnityMultiplier() public {
        _rebase(1.5e18);

        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 feeShares = (grossShares * 2) / 10_000;

        Custody memory before = _snapshot(address(stable), address(equity));
        SettledLog memory s = _settledFor(_buy(amountIn, 1));

        assertEq(s.feeShares, feeShares, "feeShares at 1.5x");
        assertEq(s.sharesOutNet + s.feeShares, grossShares, "conservation at 1.5x");
        assertEq(s.multiplierAtSettlement, 1.5e18, "multiplier recorded");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    /*//////////////////////////////////////////////////////////////
                            HAPPY PATH — SELL
    //////////////////////////////////////////////////////////////*/

    function test_Sell_ClientShareBalanceDecreasesByExactlySharesIn() public {
        _rebase(1.25e18);

        uint256 amountIn = 500e18;
        uint256 sharesIn = equity.amountToShares(amountIn);
        uint256 executable = equity.sharesToAmount(sharesIn);
        uint256 feeAmount = (executable * 2) / 10_000;

        Custody memory before = _snapshot(address(equity), address(stable));
        uint256 clientSharesBefore = equity.shares(client);
        uint256 clientStableBefore = stable.balanceOf(client);
        uint256 adapterSharesBefore = equity.shares(address(adapter));

        SettledLog memory s = _settledFor(_sell(amountIn, 1));

        assertEq(clientSharesBefore - equity.shares(client), sharesIn, "client debited exactly sharesIn");
        // Measured MID-FLOW: the adapter records its own share balance on entry to
        // `swap`, i.e. after the engine funded it and before it spent anything.
        assertEq(adapter.sharesAtEntry() - adapterSharesBefore, sharesIn, "adapter credited exactly sharesIn");

        assertEq(stable.balanceOf(feeTo), feeAmount, "fee taken in stable");
        assertEq(stable.balanceOf(client) - clientStableBefore, executable - feeAmount, "client net stable");

        assertEq(s.feeShares, 0, "feeShares is 0 on a sell");
        assertEq(s.sharesOutNet, 0, "sharesOutNet is 0 on a sell");
        assertGt(s.sharesIn, 0, "sharesIn recorded on a sell");
        assertLe(s.amountInExecuted, amountIn, "amountInExecuted <= o.amountIn");
        assertFalse(s.isBuy, "isBuy false");

        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    /*//////////////////////////////////////////////////////////////
                  EXECUTABLE INPUT — SELL-PATH REGRESSION
    //////////////////////////////////////////////////////////////*/

    function test_SellAtNonUnityMultiplier_UsesResolvedShareQuantity() public {
        // 1.333e18 does not divide the input cleanly, so the token amount
        // corresponding to a whole number of shares is strictly below the request.
        _rebase(1.333e18);
        uint256 amountIn = 777e18 + 7;

        uint256 sharesIn = equity.amountToShares(amountIn);
        uint256 executable = equity.sharesToAmount(sharesIn);
        assertLt(executable, amountIn, "setup must produce a strict floor loss");

        Custody memory before = _snapshot(address(equity), address(stable));

        // An implementation that required the adapter's delta to equal o.amountIn
        // would revert here — at EVERY non-unity multiplier, i.e. after the first
        // corporate action, forever.
        SettledLog memory s = _settledFor(_sell(amountIn, 1));

        assertEq(s.amountInExecuted, executable, "executed the resolved share quantity");
        assertLt(s.amountInExecuted, amountIn, "executed strictly less than requested");
        assertLe(amountIn - s.amountInExecuted, equity.sharesToAmount(1) + 1, "shortfall bounded by one share-worth");

        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    function test_AdapterReceivesExecutableAmountNotRequestedAmount() public {
        _rebase(1.333e18);
        uint256 amountIn = 777e18 + 7;
        uint256 executable = equity.sharesToAmount(equity.amountToShares(amountIn));

        Custody memory before = _snapshot(address(equity), address(stable));
        _submit(_sell(amountIn, 1));

        assertEq(adapter.lastAmountIn(), executable, "adapter called with the executable amount");
        assertLt(adapter.lastAmountIn(), amountIn, "adapter NOT called with the requested amount");
        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    /*//////////////////////////////////////////////////////////////
                MEASUREMENT — SHARE DELTA OVER BALANCE DELTA
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructed so the two measurements provably disagree.
    ///
    ///      At m = 1.5e18 with the engine already holding 1 wei-share (donated),
    ///      a buy that moves 3 wei-shares gives:
    ///
    ///        balanceOf before = floor(1 * 1.5) = 1
    ///        balanceOf after  = floor(4 * 1.5) = 6      -> balance delta = 5
    ///        true value moved = floor(3 * 1.5) = 4
    ///
    ///      i.e. floor(4m) - floor(1m) != floor(3m). A `balanceOf`-delta
    ///      implementation would have recorded 5 tokens for a movement genuinely
    ///      worth 4, and would have credited the client that phantom wei. Measuring
    ///      the SHARE delta records 3 shares exactly, and the reported token figure
    ///      is derived from it as 4.
    function test_ShareDeltaMeasurement_ExactWhereBalanceDeltaWouldNotBe() public {
        _rebase(1.5e18);

        // Donation that gives the engine the awkward share remainder.
        vm.prank(admin);
        equity.mint(donor, 1);
        vm.prank(donor);
        equity.transferShares(address(engine), 1);
        assertEq(equity.shares(address(engine)), 1, "engine seeded with one wei-share");

        uint256 engineBalanceBefore = equity.balanceOf(address(engine));
        assertEq(engineBalanceBefore, 1, "floor(1 * 1.5)");

        Custody memory before = _snapshot(address(stable), address(equity));

        // 5 stable in at rate 1 -> the adapter transfers 5 equity TOKENS, which
        // resolves to floor(5 / 1.5) = 3 shares.
        SettledLog memory s = _settledFor(_buy(5, 1));

        assertEq(s.feeShares, 0, "below the fee threshold, so net == gross");
        assertEq(s.sharesOutNet, 3, "recorded the true share delta");
        assertEq(s.amountOutNet, equity.sharesToAmount(3), "reported amount derived from shares");
        assertEq(s.amountOutNet, 4, "4 tokens, not the 5 a balance delta would show");

        // The discrepancy this test exists to pin down.
        assertTrue(equity.sharesToAmount(3) != 5, "balance delta and share value disagree");

        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    /*//////////////////////////////////////////////////////////////
                     DONATION GRIEFING — ADAPTER SIDE
    //////////////////////////////////////////////////////////////*/

    function test_AdapterWithPreExistingBalance_BuySucceeds() public {
        stable.mint(address(adapter), 1);
        uint256 adapterBefore = stable.balanceOf(address(adapter));

        Custody memory before = _snapshot(address(stable), address(equity));
        _submit(_buy(1_000e18, 1));

        assertEq(stable.balanceOf(address(adapter)), adapterBefore, "donated wei untouched");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_AdapterWithPreExistingBalance_SellSucceeds() public {
        _rebase(1.5e18);
        vm.prank(admin);
        equity.mint(address(adapter), 7);

        uint256 adapterSharesBefore = equity.shares(address(adapter));
        Custody memory before = _snapshot(address(equity), address(stable));

        _submit(_sell(500e18, 1));

        // Within the documented one wei-share tolerance, and nowhere near the
        // donated 7 — the donation is not consumed.
        uint256 nowShares = equity.shares(address(adapter));
        uint256 drift =
            nowShares > adapterSharesBefore ? nowShares - adapterSharesBefore : adapterSharesBefore - nowShares;
        assertLe(drift, 1, "donated shares untouched beyond rounding");
        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    function test_SweepingAdapterIsRejected() public {
        stable.mint(address(adapter), 1);
        adapter.setMode(MockAdapter.Mode.SweepAll);

        // The check is EQUALITY against a snapshot, so it catches consuming too
        // much just as it catches retaining too much. Without it, that single
        // donated wei would make this adapter permanently unusable.
        vm.prank(client);
        vm.expectRevert(SettlementEngine.AdapterRetainedFunds.selector);
        router.submitOrder(_buy(1_000e18, 1));
    }

    /*//////////////////////////////////////////////////////////////
                      DONATION GRIEFING — ENGINE SIDE
    //////////////////////////////////////////////////////////////*/

    function test_EngineWithDonatedAssetIn_SettlementSucceeds() public {
        stable.mint(address(engine), 12_345);
        Custody memory before = _snapshot(address(stable), address(equity));

        _submit(_buy(1_000e18, 1));

        assertEq(stable.balanceOf(address(engine)), 12_345, "donated assetIn exactly unchanged");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_EngineWithDonatedAssetOut_SettlementSucceeds() public {
        // assetOut on a sell is the stable.
        stable.mint(address(engine), 999);
        Custody memory before = _snapshot(address(equity), address(stable));

        _submit(_sell(500e18, 1));

        assertEq(stable.balanceOf(address(engine)), 999, "donated assetOut exactly unchanged");
        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    function test_EngineWithDonatedShares_SettlementSucceeds() public {
        vm.prank(admin);
        equity.mint(donor, 4_242);
        vm.prank(donor);
        equity.transferShares(address(engine), 4_242);

        Custody memory before = _snapshot(address(stable), address(equity));
        _submit(_buy(1_000e18, 1));

        assertEq(equity.shares(address(engine)), 4_242, "donated shares exactly unchanged");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER HASH CORRELATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Regression guard: hashing the MODIFIED executable copy instead of the
    ///      original order would break correlation on sells only, while buys kept
    ///      working and hid the bug.
    function test_OrderHashMatchesRouterAcrossSell() public {
        _rebase(1.333e18);

        vm.recordLogs();
        _submit(_sell(777e18 + 7, 1));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 submittedHash;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == ORDER_SUBMITTED_TOPIC) {
                submittedHash = entries[i].topics[1];
            }
        }

        SettledLog memory s = _lastSettled(entries);
        assertTrue(submittedHash != bytes32(0), "OrderSubmitted not found");
        assertEq(s.orderHash, submittedHash, "Settled hash must match the Router's");
    }

    /*//////////////////////////////////////////////////////////////
                     HEADLINE — SETTLEMENT ACROSS A REBASE
    //////////////////////////////////////////////////////////////*/

    function test_SettlementCorrectBeforeRebase() public {
        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 feeShares = (grossShares * 2) / 10_000;

        Custody memory before = _snapshot(address(stable), address(equity));
        SettledLog memory s = _settledFor(_buy(amountIn, 1));

        assertEq(s.multiplierAtSettlement, 1e18, "settled at the unity multiplier");
        assertEq(s.sharesOutNet, grossShares - feeShares, "net shares at 1x");
        assertEq(equity.shares(client), 1e24 + grossShares - feeShares, "client share position");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_CorporateActionDoesNotAffectRecordedShares() public {
        _submit(_buy(1_000e18, 1));

        uint256 clientShares = equity.shares(client);
        uint256 feeShares = equity.shares(feeTo);
        uint256 clientBalance = equity.balanceOf(client);
        uint256 feeBalance = equity.balanceOf(feeTo);

        _rebase(2e18); // exactly 2x, so the balance ratio is checkable exactly

        assertEq(equity.shares(client), clientShares, "client shares unchanged by corporate action");
        assertEq(equity.shares(feeTo), feeShares, "fee recipient shares unchanged");
        assertEq(equity.balanceOf(client), clientBalance * 2, "client balance scaled by the ratio");
        assertEq(equity.balanceOf(feeTo), feeBalance * 2, "fee recipient balance scaled by the ratio");
    }

    function test_SettlementCorrectAfterRebase() public {
        uint256 amountIn = 1_000e18;

        uint256 sharesPerStableBefore = equity.amountToShares(amountIn);
        _submit(_buy(amountIn, 1));

        _rebase(2e18);

        Custody memory before = _snapshot(address(stable), address(equity));
        SettledLog memory s = _settledFor(_buy(amountIn, 1));

        uint256 grossSharesAfter = equity.amountToShares(amountIn);
        assertEq(s.multiplierAtSettlement, 2e18, "settled at the new multiplier");
        assertEq(s.sharesOutNet + s.feeShares, grossSharesAfter, "conservation at the new multiplier");

        // The same stable buys HALF the shares at 2x. Consistent with the new
        // multiplier, not the old one — the assertion that would fail if any
        // conversion had been cached across the corporate action.
        assertEq(grossSharesAfter, sharesPerStableBefore / 2, "shares per stable follow the new multiplier");

        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_NoValueCreatedOrDestroyedAcrossRebase() public {
        _submit(_buy(1_000e18, 1));
        _submit(_sell(300e18, 1));

        uint256 totalBefore = equity.totalShares();
        uint256 sumBefore = equity.shares(client) + equity.shares(feeTo) + equity.shares(address(adapter))
            + equity.shares(sink) + equity.shares(address(engine));
        assertEq(sumBefore, totalBefore, "share sum accounts for every holder before");
        assertEq(totalBefore, shareRegistry.allocatedShares(address(equity)), "backing reconciles before");

        _rebase(3e18);

        uint256 totalAfter = equity.totalShares();
        uint256 sumAfter = equity.shares(client) + equity.shares(feeTo) + equity.shares(address(adapter))
            + equity.shares(sink) + equity.shares(address(engine));

        assertEq(totalAfter, totalBefore, "total share count IDENTICAL across a corporate action");
        assertEq(sumAfter, sumBefore, "every holder's share count identical");
        assertEq(totalAfter, shareRegistry.allocatedShares(address(equity)), "backing still reconciles after");
    }

    /*//////////////////////////////////////////////////////////////
                            ZERO-FEE TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_DustBuy_ZeroFeeShares_DoesNotRevert() public {
        // grossShares = 3_000 < 5_000, so 2 bps floors to zero.
        uint256 amountIn = 3_000;
        assertLt(equity.amountToShares(amountIn) * 2 / 10_000, 1, "setup must floor the fee to zero");

        Custody memory before = _snapshot(address(stable), address(equity));

        vm.recordLogs();
        _submit(_buy(amountIn, 1));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        SettledLog memory s = _lastSettled(entries);
        assertEq(s.feeShares, 0, "fee floored to zero");
        assertEq(s.sharesOutNet, equity.amountToShares(amountIn), "client receives the whole gross");
        assertEq(equity.shares(feeTo), 0, "fee recipient received nothing");

        // Stronger than a balance check: prove no transfer was ATTEMPTED, which is
        // what would have reverted inside the token.
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(equity) && entries[i].topics.length == 3
                    && entries[i].topics[0] == TRANSFER_TOPIC
            ) {
                assertTrue(
                    address(uint160(uint256(entries[i].topics[2]))) != feeTo,
                    "no transfer to the fee recipient was made"
                );
            }
        }

        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_DustSell_ZeroFeeAmount_DoesNotRevert() public {
        uint256 amountIn = 3_000;
        Custody memory before = _snapshot(address(equity), address(stable));

        SettledLog memory s = _settledFor(_sell(amountIn, 1));

        assertEq(s.feeAmount, 0, "stable fee floored to zero");
        assertEq(stable.balanceOf(feeTo), 0, "fee recipient received nothing");
        assertEq(s.amountOutNet, s.amountInExecuted, "net == gross when the fee is zero");
        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    /*//////////////////////////////////////////////////////////////
                      SELL-SIDE RETENTION TOLERANCE
    //////////////////////////////////////////////////////////////*/

    function test_SellRetentionCheck_ToleratesOneWeiShareDrift() public {
        _rebase(1.5e18);

        adapter.setMode(MockAdapter.Mode.RetainInput);
        adapter.setRetainAmount(1);
        adapter.setShareBaseline(equity.shares(address(adapter)));

        Custody memory before = _snapshot(address(equity), address(stable));
        uint256 adapterSharesBefore = equity.shares(address(adapter));

        _submit(_sell(500e18, 1));

        assertEq(equity.shares(address(adapter)) - adapterSharesBefore, 1, "drift is exactly one wei-share");
        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    function test_SellRetentionCheck_RejectsMeaningfulRetention() public {
        _rebase(1.5e18);

        adapter.setMode(MockAdapter.Mode.RetainInput);
        adapter.setRetainAmount(1_000);
        adapter.setShareBaseline(equity.shares(address(adapter)));

        vm.prank(client);
        vm.expectRevert(SettlementEngine.AdapterRetainedFunds.selector);
        router.submitOrder(_sell(500e18, 1));
    }

    function test_BuyRetentionCheck_RejectsAnyRetention() public {
        adapter.setMode(MockAdapter.Mode.RetainInput);
        adapter.setRetainAmount(1);

        // No tolerance on the buy leg: the stable involves no conversion, so the
        // comparison is exact and one wei of retention is one wei too many.
        vm.prank(client);
        vm.expectRevert(SettlementEngine.AdapterRetainedFunds.selector);
        router.submitOrder(_buy(1_000e18, 1));
    }

    /*//////////////////////////////////////////////////////////////
                        FEE RECIPIENT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_SetFeeRecipientToEngine_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidFeeRecipient.selector, address(engine)));
        engine.setFeeRecipient(address(engine));
    }

    function test_SetFeeRecipientToRegisteredRebasingToken_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidFeeRecipient.selector, address(equity)));
        engine.setFeeRecipient(address(equity));
    }

    function test_SetFeeRecipientToZero_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(SettlementEngine.ZeroAddress.selector);
        engine.setFeeRecipient(address(0));
    }

    function test_SetFeeRecipientFromNonAdmin_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        engine.setFeeRecipient(stranger);
    }

    /// @dev Proves the CONSTRUCTOR runs the same validation as the setter. The
    ///      engine's own address is precomputed so it can be passed to its own
    ///      constructor — the exact misconfiguration that would strand fee revenue
    ///      permanently, given there is no rescue path.
    function test_ConstructorRejectsEngineAsFeeRecipient() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidFeeRecipient.selector, predicted));
        new SettlementEngine(admin, venues, predicted);
    }

    function test_SetFeeRecipient_UpdatesAndRoutesFeesToTheNewAddress() public {
        address newFeeTo = makeAddr("newFeeTo");

        vm.prank(admin);
        engine.setFeeRecipient(newFeeTo);
        assertEq(engine.feeRecipient(), newFeeTo, "recipient updated");

        _submit(_buy(1_000e18, 1));
        assertGt(equity.shares(newFeeTo), 0, "new recipient paid");
        assertEq(equity.shares(feeTo), 0, "old recipient not paid");
    }

    /*//////////////////////////////////////////////////////////////
                   REBASING TOKEN REGISTRATION VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RegisterRebasingToken_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(SettlementEngine.ZeroAddress.selector);
        engine.registerRebasingToken(address(0), true);
    }

    function test_RegisterRebasingToken_EOA_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidRebasingToken.selector, stranger));
        engine.registerRebasingToken(stranger, true);
    }

    /// @dev The realistic misconfiguration: a real, deployed contract that is the
    ///      WRONG contract. `code.length` alone passes it; the probe is what
    ///      catches it.
    function test_RegisterRebasingToken_ContractWithoutMultiplier_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidRebasingToken.selector, address(stable)));
        engine.registerRebasingToken(address(stable), true);
    }

    function test_RegisterRebasingToken_ZeroMultiplier_Reverts() public {
        MockZeroMultiplierToken bad = new MockZeroMultiplierToken();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InvalidRebasingToken.selector, address(bad)));
        engine.registerRebasingToken(address(bad), true);
    }

    function test_RegisterRebasingToken_FromNonAdmin_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        engine.registerRebasingToken(address(equityB), true);
    }

    /// @dev THE ASYMMETRY. Deregistration applies no validation at all, so a token
    ///      that has become non-conforming can always be removed. Deregistering an
    ///      EOA and a zero address — both of which are REJECTED on the way in —
    ///      must succeed on the way out.
    function test_DeregisterRebasingToken_SkipsValidation() public {
        vm.startPrank(admin);
        engine.registerRebasingToken(address(equityB), true);
        assertTrue(engine.isRebasingToken(address(equityB)), "registered");

        engine.registerRebasingToken(address(equityB), false);
        assertFalse(engine.isRebasingToken(address(equityB)), "deregistered");

        // Neither of these would pass the registration probe.
        engine.registerRebasingToken(stranger, false);
        engine.registerRebasingToken(address(0), false);
        vm.stopPrank();

        assertFalse(engine.isRebasingToken(stranger), "EOA deregistration accepted");
    }

    /*//////////////////////////////////////////////////////////////
                             NEGATIVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SettleFromNonRouter_RevertsOnlyRouter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.OnlyRouter.selector, stranger, address(router)));
        engine.settle(_buy(1_000e18, 1), VENUE, address(adapter));
    }

    function test_AdapterNotMatchingRegistry_RevertsAdapterMismatch() public {
        MockAdapter rogue = new MockAdapter(sink, IRebasingEquityToken(address(equity)));

        // Even the ONLY permitted caller cannot name its own adapter.
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.AdapterMismatch.selector, VENUE, address(rogue)));
        engine.settle(_buy(1_000e18, 1), VENUE, address(rogue));
    }

    function test_ExpiredDeadline_RevertsDeadlineExpired() public {
        OrderTypes.Order memory o = _buy(1_000e18, 1);
        o.deadline = block.timestamp - 1;

        // Called directly on the engine: the Router would have rejected it first,
        // so this proves the engine re-checks rather than assuming.
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.DeadlineExpired.selector, o.deadline, block.timestamp));
        engine.settle(o, VENUE, address(adapter));
    }

    function test_RebaseAttackerAdapter_RevertsMultiplierChanged() public {
        adapter.setMode(MockAdapter.Mode.RebaseAttack);
        adapter.setAttackMultiplier(2e18);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.MultiplierChangedDuringSettlement.selector, 1e18, 2e18));
        router.submitOrder(_buy(1_000e18, 1));
    }

    /// @dev Proves the ENGINE's own guard, independently of the Router's.
    ///      A dedicated engine is deployed whose router IS the adapter, so the
    ///      re-entrant call passes `onlyRouter` and reaches `nonReentrant`. In the
    ///      production wiring the Router's guard would stop it first, which would
    ///      otherwise leave this guard unexercised.
    function test_ReentrantAdapter_ReentrancyGuardFires() public {
        ReentrantRouterAdapter attacker = new ReentrantRouterAdapter();

        bytes32 reentrantVenue = keccak256("REENTRANT_VENUE");
        vm.startPrank(admin);
        SettlementEngine e2 = new SettlementEngine(admin, venues, feeTo);
        e2.initializeRouter(address(attacker));
        e2.registerRebasingToken(address(equity), true);
        venues.setAdapter(reentrantVenue, address(attacker));
        vm.stopPrank();

        vm.prank(client);
        stable.approve(address(e2), type(uint256).max);

        OrderTypes.Order memory o = _order(address(stable), address(equity), 1_000e18, 1);
        o.venueId = reentrantVenue;
        attacker.arm(e2, o, reentrantVenue);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.trigger();
    }

    function test_AdapterReturnsZeroOut_RevertsZeroAmount() public {
        adapter.setOutputRate(0);

        vm.prank(client);
        vm.expectRevert(SettlementEngine.ZeroAmount.selector);
        router.submitOrder(_buy(1_000e18, 1));
    }

    function test_BothAssetsRebasing_RevertsUnsupportedAssetPair() public {
        vm.prank(admin);
        engine.registerRebasingToken(address(equityB), true);

        vm.prank(admin);
        equityB.mint(client, 1e24);
        vm.prank(client);
        equityB.approve(address(engine), type(uint256).max);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementEngine.UnsupportedAssetPair.selector, address(equity), address(equityB))
        );
        router.submitOrder(_order(address(equity), address(equityB), 100e18, 1));
    }

    function test_NeitherAssetRebasing_RevertsNoRebasingLeg() public {
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementEngine.NoRebasingLeg.selector, address(stable), address(stableB))
        );
        router.submitOrder(_order(address(stable), address(stableB), 100e18, 1));
    }

    function test_SellResolvingToZeroShares_RevertsZeroAmount() public {
        // A multiplier so large that one wei of token is worth less than one share.
        _rebase(1e30);

        vm.prank(client);
        vm.expectRevert(SettlementEngine.ZeroAmount.selector);
        router.submitOrder(_sell(1, 1));
    }

    function test_InsufficientAllowanceToEngine_Reverts() public {
        vm.prank(client);
        stable.approve(address(engine), 0);

        vm.prank(client);
        vm.expectRevert();
        router.submitOrder(_buy(1_000e18, 1));
    }

    function test_InsufficientClientBalance_Reverts() public {
        uint256 tooMuch = stable.balanceOf(client) + 1;

        vm.prank(client);
        vm.expectRevert();
        router.submitOrder(_buy(tooMuch, 1));
    }

    function test_RevertingAdapter_PropagatesAndSettlesNothing() public {
        adapter.setMode(MockAdapter.Mode.Reverting);
        Custody memory before = _snapshot(address(stable), address(equity));
        uint256 clientSharesBefore = equity.shares(client);

        vm.prank(client);
        vm.expectRevert("MockAdapter: forced revert");
        router.submitOrder(_buy(1_000e18, 1));

        // No try/catch anywhere: a failed leg unwinds the whole settlement,
        // including the transfer that had already funded the adapter.
        assertEq(equity.shares(client), clientSharesBefore, "no partial settlement");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    /*//////////////////////////////////////////////////////////////
                    MIN AMOUNT OUT — THE ORDERING PROOF
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructed precisely: the bound is set to the GROSS output, so the
    ///      2 bps fee ALONE is what pushes the net below it. An implementation
    ///      that checked slippage before the fee would pass this. A looser bound
    ///      would not distinguish the two orderings at all.
    function test_MinAmountOutAtGross_RevertsInsufficientOutput() public {
        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 feeShares = (grossShares * 2) / 10_000;
        uint256 grossAmount = equity.sharesToAmount(grossShares);
        uint256 netAmount = equity.sharesToAmount(grossShares - feeShares);
        assertLt(netAmount, grossAmount, "the fee must actually move the figure");

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SettlementEngine.InsufficientOutput.selector, grossAmount, netAmount));
        router.submitOrder(_buy(amountIn, grossAmount));
    }

    function test_MinAmountOutAtNet_Succeeds() public {
        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 netAmount = equity.sharesToAmount(grossShares - (grossShares * 2) / 10_000);

        Custody memory before = _snapshot(address(stable), address(equity));
        uint256 out = _submit(_buy(amountIn, netAmount));

        assertEq(out, netAmount, "settles at exactly the net bound");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    /*//////////////////////////////////////////////////////////////
                          ADAPTER MISREPORTING
    //////////////////////////////////////////////////////////////*/

    function test_UnderReportingAdapter_ClientReceivesFullMeasuredAmount() public {
        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 netShares = grossShares - (grossShares * 2) / 10_000;

        adapter.setMode(MockAdapter.Mode.UnderReport);

        Custody memory before = _snapshot(address(stable), address(equity));
        uint256 clientSharesBefore = equity.shares(client);
        SettledLog memory s = _settledFor(_buy(amountIn, 1));

        // The adapter reported half. The engine measured the truth.
        assertEq(equity.shares(client) - clientSharesBefore, netShares, "client got the measured amount");
        assertEq(s.sharesOutNet, netShares, "event records the measured amount");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    function test_OverReportingAdapter_NoPhantomValueDelivered() public {
        uint256 amountIn = 1_000e18;
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 netShares = grossShares - (grossShares * 2) / 10_000;

        adapter.setMode(MockAdapter.Mode.OverReport);

        Custody memory before = _snapshot(address(stable), address(equity));
        uint256 clientSharesBefore = equity.shares(client);
        uint256 out = _submit(_buy(amountIn, 1));

        assertEq(equity.shares(client) - clientSharesBefore, netShares, "no phantom shares delivered");
        assertEq(out, equity.sharesToAmount(netShares), "return value is the measured figure, not the claim");
        _assertCustodyUnchanged(before, address(stable), address(equity), false);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Engine properties only. None of these assert anything about the
    ///      venue's pricing — that belongs to the adapter, not to this contract.
    function testFuzz_FeeSharesPlusNetSharesEqualsGrossShares(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 1e22);

        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 clientBefore = equity.shares(client);

        SettledLog memory s = _settledFor(_buy(amountIn, 1));

        assertEq(s.feeShares + s.sharesOutNet, grossShares, "conservation holds for every size");
        assertEq(equity.shares(client) - clientBefore, s.sharesOutNet, "client received exactly the net");
        assertEq(equity.shares(feeTo), s.feeShares, "fee recipient received exactly the fee");
    }

    function testFuzz_SellDebitEqualsAdapterCredit(uint256 amountIn, uint256 multiplier) public {
        multiplier = bound(multiplier, 1e18, 1e24);
        if (multiplier > 1e18) _rebase(multiplier);

        // Large enough that the request resolves to at least one share.
        amountIn = bound(amountIn, equity.sharesToAmount(1e6) + 1, 1e22);

        uint256 sharesIn = equity.amountToShares(amountIn);
        vm.assume(sharesIn > 0);

        uint256 clientBefore = equity.shares(client);
        uint256 adapterBefore = equity.shares(address(adapter));

        _submit(_sell(amountIn, 1));

        assertEq(clientBefore - equity.shares(client), sharesIn, "client debited sharesIn");
        assertEq(adapter.sharesAtEntry() - adapterBefore, sharesIn, "adapter credited the identical quantity");
    }

    function testFuzz_AmountOutNetNeverBelowMinAmountOut(uint256 amountIn, uint256 minOut) public {
        amountIn = bound(amountIn, 1e12, 1e22);
        uint256 grossShares = equity.amountToShares(amountIn);
        uint256 netAmount = equity.sharesToAmount(grossShares - (grossShares * 2) / 10_000);
        minOut = bound(minOut, 1, netAmount);

        uint256 out = _submit(_buy(amountIn, minOut));
        assertGe(out, minOut, "a successful settlement never delivers below the bound");
    }

    function testFuzz_AmountInExecutedNeverExceedsRequested(uint256 amountIn, uint256 multiplier) public {
        multiplier = bound(multiplier, 1e18, 1e24);
        if (multiplier > 1e18) _rebase(multiplier);

        amountIn = bound(amountIn, equity.sharesToAmount(1e6) + 1, 1e22);
        vm.assume(equity.amountToShares(amountIn) > 0);

        SettledLog memory s = _settledFor(_sell(amountIn, 1));

        assertLe(s.amountInExecuted, amountIn, "never executes more than requested");
        // Derivation: sharesIn = floor(A*1e18/m) loses < 1 share, and re-deriving
        // the amount floors again, losing < 1 wei. So the shortfall is bounded by
        // one share-worth plus one wei.
        assertLe(amountIn - s.amountInExecuted, equity.sharesToAmount(1) + 1, "shortfall under one share-worth");
    }

    function testFuzz_EngineDonationsAreNeverTouched(
        uint256 donatedIn,
        uint256 donatedOut,
        uint256 donatedShares,
        uint256 amountIn,
        uint256 multiplier
    ) public {
        multiplier = bound(multiplier, 1e18, 1e24);
        if (multiplier > 1e18) _rebase(multiplier);

        donatedIn = bound(donatedIn, 0, 1e24);
        donatedOut = bound(donatedOut, 0, 1e24);
        donatedShares = bound(donatedShares, 0, 1e20);
        amountIn = bound(amountIn, equity.sharesToAmount(1e6) + 1, 1e22);
        vm.assume(equity.amountToShares(amountIn) > 0);

        if (donatedIn > 0) stable.mint(address(engine), donatedIn);
        if (donatedOut > 0) stable.mint(address(engine), donatedOut);
        if (donatedShares > 0) {
            vm.prank(admin);
            equity.mint(donor, donatedShares);
            vm.prank(donor);
            equity.transferShares(address(engine), donatedShares);
        }

        uint256 stableBefore = stable.balanceOf(address(engine));
        uint256 sharesBefore = equity.shares(address(engine));

        _submit(_buy(amountIn, 1));

        assertEq(stable.balanceOf(address(engine)), stableBefore, "donated stable exactly unchanged");
        assertEq(equity.shares(address(engine)), sharesBefore, "donated shares exactly unchanged");
    }

    function testFuzz_AdapterDonationsAreNeverTouched(uint256 donated, uint256 amountIn, uint256 multiplier) public {
        multiplier = bound(multiplier, 1e18, 1e24);
        if (multiplier > 1e18) _rebase(multiplier);

        donated = bound(donated, 0, 1e24);
        amountIn = bound(amountIn, 1e12, 1e22);

        if (donated > 0) stable.mint(address(adapter), donated);
        uint256 adapterBefore = stable.balanceOf(address(adapter));

        _submit(_buy(amountIn, 1));

        assertEq(stable.balanceOf(address(adapter)), adapterBefore, "adapter's pre-existing balance untouched");
    }

    /*//////////////////////////////////////////////////////////////
                     NON-CONFORMING TOKEN ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The arrival assertion is not redundant with the transfer's return
    ///      value: this token returns TRUE while delivering one wei less, so only
    ///      a measured delta catches it. Without the check the adapter would be
    ///      funded below what its swap is about to be priced for, and the failure
    ///      would surface as an opaque venue-side revert with funds in flight.
    function test_ShortFundingOfAdapter_RevertsInputTransferMismatch() public {
        MisbehavingStable bad = new MisbehavingStable("Bad", "BAD");
        bad.mint(client, 1e24);
        bad.mint(address(adapter), 1e24);
        vm.prank(client);
        bad.approve(address(engine), type(uint256).max);
        bad.setShort(true);

        vm.prank(client);
        vm.expectRevert(SettlementEngine.InputTransferMismatch.selector);
        router.submitOrder(_order(address(bad), address(equity), 1_000e18, 1));
    }

    /// @dev Same assertion on the SELL leg, where the input moves in shares. The
    ///      well-behaved token cannot produce this — its share transfers are exact
    ///      — so reaching the branch takes a token that shorts them.
    function test_ShortShareTransferFrom_RevertsInputTransferMismatch() public {
        ShortTransferEquity bad = new ShortTransferEquity();
        bad.mint(client, 1e24);

        vm.prank(admin);
        engine.registerRebasingToken(address(bad), true);

        vm.prank(client);
        bad.approve(address(engine), type(uint256).max);

        vm.prank(client);
        vm.expectRevert(SettlementEngine.InputTransferMismatch.selector);
        router.submitOrder(_order(address(bad), address(stable), 1_000e18, 1));
    }

    /// @dev The subtler failure STEP 10 catches: not a donation, but a delivery
    ///      that silently under-sent. Caught in the transaction that created the
    ///      residue rather than accumulating unnoticed across settlements.
    function test_UnderSendingOutputToken_RevertsEngineRetainedFunds() public {
        MisbehavingStable bad = new MisbehavingStable("Bad", "BAD");
        bad.mint(address(adapter), 1e24);
        bad.setShort(true);

        vm.prank(client);
        vm.expectRevert(SettlementEngine.EngineRetainedFunds.selector);
        router.submitOrder(_order(address(equity), address(bad), 500e18, 1));
    }

    /*//////////////////////////////////////////////////////////////
                        REMAINING GUARD COVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(SettlementEngine.ZeroAddress.selector);
        new SettlementEngine(address(0), venues, feeTo);
    }

    function test_ConstructorRejectsZeroVenueRegistry() public {
        vm.expectRevert(SettlementEngine.ZeroAddress.selector);
        new SettlementEngine(admin, VenueRegistry(address(0)), feeTo);
    }

    /// @dev Reached only by calling the engine directly: the Router rejects a zero
    ///      `amountIn` first. The engine re-checks because the Router is not a
    ///      trust anchor.
    function test_SettleWithZeroAmountIn_RevertsZeroAmount() public {
        vm.prank(address(router));
        vm.expectRevert(SettlementEngine.ZeroAmount.selector);
        engine.settle(_buy(0, 1), VENUE, address(adapter));
    }

    function test_SellAdapterReturnsZeroOut_RevertsZeroAmount() public {
        adapter.setOutputRate(0);

        vm.prank(client);
        vm.expectRevert(SettlementEngine.ZeroAmount.selector);
        router.submitOrder(_sell(500e18, 1));
    }

    /*//////////////////////////////////////////////////////////////
                    EXACT ALLOWANCE — THE SELL-LEG DEBIT

        The allowance the engine consumes on a sell is TOKEN-denominated, while
        the quantity it moves is SHARE-denominated. `transferSharesFrom` debits
        ceil(sharesIn * m / 1e18) — the CEIL, not the floor — so that a spender
        can never move more value than was approved.

        ================== SCOPE — A4 ONLY, NOT A5 ==================
        These properties cover the A4 case ONLY: `sharesIn` is RECOMPUTED from
        `o.amountIn` at the SETTLEMENT-TIME multiplier, so

            sharesIn = floor(amountIn * 1e18 / m)

        and therefore ceil(sharesIn * m / 1e18) <= amountIn by construction.
        The allowance always fits. This is MULTIPLIER-INDEPENDENT: it holds at
        whatever m happens to be when settlement runs, because sharesIn was
        derived from that same m moments earlier.

        They do NOT cover the A5 case. There, a share quantity S is FIXED at
        approval time via `approveShares(S)` and consumed LATER at a different
        multiplier. S was not derived from the current allowance, so the proof
        does not apply: the stored token allowance ceil(S * m_old / 1e18)
        permits strictly FEWER than S shares once m > m_old, and the sell
        reverts with InsufficientAllowance. That is the liveness failure a
        `topUpEngineShares` path exists to fix, and NO PROPERTY IN THIS FILE
        MAKES IT REDUNDANT.
        =============================================================
    //////////////////////////////////////////////////////////////*/

    /// @dev Replicates the token's internal `_toAmountCeil`, which is not exposed
    ///      publicly. Not an unchecked copy: the assertions below compare the
    ///      REAL allowance debit against this figure for exact equality, so any
    ///      divergence between the two fails the test rather than hiding in it.
    function _ceilSharesToAmount(uint256 shareAmount) internal view returns (uint256) {
        uint256 m = equity.multiplier();
        return (shareAmount * m + WAD - 1) / WAD;
    }

    function test_SellWithExactAllowance_DebitsExactlyCeilOfSharesIn() public {
        // 1.333e18 does not divide the input cleanly, so the ceil and the floor
        // genuinely differ and the assertion is not vacuous.
        _rebase(1.333e18);
        uint256 amountIn = 777e18 + 7;

        // Exactly the requested amount, NOT the infinite sentinel — an infinite
        // allowance is never decremented, so it could not measure a debit at all.
        vm.prank(client);
        equity.approve(address(engine), amountIn);

        uint256 sharesIn = equity.amountToShares(amountIn);
        uint256 expectedDebit = _ceilSharesToAmount(sharesIn);
        assertGt(expectedDebit, equity.sharesToAmount(sharesIn), "setup: ceil must differ from floor");

        uint256 allowanceBefore = equity.allowance(client, address(engine));
        Custody memory before = _snapshot(address(equity), address(stable));

        _submit(_sell(amountIn, 1));

        uint256 debited = allowanceBefore - equity.allowance(client, address(engine));

        // The EXACT figure, not a bound on the residual: this is the precise
        // statement of what the token does, and it catches a change to either
        // conversion that an inequality would let through.
        assertEq(debited, expectedDebit, "debit must equal ceil(sharesIn)");
        assertLe(debited, amountIn, "debit must never exceed what was approved");

        _assertCustodyUnchanged(before, address(equity), address(stable), true);
    }

    function testFuzz_SellNeverDebitsMoreThanApproved(uint256 amountIn, uint256 multiplier) public {
        multiplier = bound(multiplier, 1e18, 1e24);
        if (multiplier > 1e18) _rebase(multiplier);

        amountIn = bound(amountIn, equity.sharesToAmount(1e6) + 1, 1e22);
        uint256 sharesIn = equity.amountToShares(amountIn);
        vm.assume(sharesIn > 0);

        vm.prank(client);
        equity.approve(address(engine), amountIn);

        uint256 expectedDebit = _ceilSharesToAmount(sharesIn);
        uint256 allowanceBefore = equity.allowance(client, address(engine));

        _submit(_sell(amountIn, 1));

        uint256 debited = allowanceBefore - equity.allowance(client, address(engine));
        assertEq(debited, expectedDebit, "debit == ceil(sharesIn)");
        assertLe(debited, amountIn, "debit <= approved");
    }

    // NOTE: there is deliberately NO buy-then-sell round-trip test. It would
    // measure the mock adapter's pricing curve, not this engine's accounting — a
    // pass would confirm only that the mock is well behaved.
}
