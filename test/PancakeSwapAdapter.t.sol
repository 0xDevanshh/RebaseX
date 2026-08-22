// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TradingModule} from "../src/accounts/TradingModule.sol";
import {PancakeSwapAdapter} from "../src/adapters/PancakeSwapAdapter.sol";
import {Router} from "../src/core/Router.sol";
import {SettlementEngine} from "../src/core/SettlementEngine.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {MockStable} from "../src/mocks/MockStable.sol";
import {VenueRegistry} from "../src/router/VenueRegistry.sol";

import {SafeDeployer} from "./helpers/SafeDeployer.sol";

/// @title MockPancakeRouter
/// @notice Configurable stand-in for a real PancakeSwap V2 router, implementing
///         only {IPancakeRouter02} plus one decoy function.
/// @dev Lets {PancakeSwapAdapter} be tested against controllable reserves/rate
///      without a fork, and records what it was actually called with so tests can
///      assert on the adapter's call, not just the end state.
contract MockPancakeRouter is IPancakeRouter02 {
    using SafeERC20 for IERC20;

    /// @dev Output amount `getAmountsOut` reports and `swap...` actually pays —
    ///      the mock's stand-in for "the pool's current rate".
    uint256 public configuredAmountOut;

    /// @dev Simulates "no pair exists for this path" — {getAmountsOut} on a real
    ///      router reverts rather than returning zero for that case.
    bool public quoteReverts;

    /// @dev Simulates the venue itself failing mid-swap (e.g. expired deadline,
    ///      insufficient output on the router's own check).
    bool public swapReverts;

    bool public supportingFeeVariantCalled;
    bool public plainVariantCalled;
    uint256 public lastAmountOutMin;
    address public lastTo;
    uint256 public lastDeadline;

    /// @dev The caller's (the adapter's) allowance to this router, read AT THE
    ///      START of the call — before `transferFrom` and before the adapter's
    ///      own post-call reset — because that reset makes the allowance
    ///      unobservable to the test by the time control returns to it.
    uint256 public lastAllowanceSeen;

    function setAmountOut(uint256 v) external {
        configuredAmountOut = v;
    }

    function setQuoteReverts(bool v) external {
        quoteReverts = v;
    }

    function setSwapReverts(bool v) external {
        swapReverts = v;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        if (quoteReverts) revert("MockPancakeRouter: no pair");

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; ++i) {
            amounts[i] = configuredAmountOut;
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        if (swapReverts) revert("MockPancakeRouter: forced revert");

        supportingFeeVariantCalled = true;
        lastAmountOutMin = amountOutMin;
        lastTo = to;
        lastDeadline = deadline;
        lastAllowanceSeen = IERC20(path[0]).allowance(msg.sender, address(this));

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        if (configuredAmountOut > 0) {
            IERC20(path[path.length - 1]).safeTransfer(to, configuredAmountOut);
        }
    }

    /// @dev DECOY. {IPancakeRouter02} — the only interface {PancakeSwapAdapter}
    ///      imports — never declares this selector, so the adapter cannot reach
    ///      it through that type. Present only so a regression test can assert
    ///      this was NOT called, pinning the fee-on-transfer choice even against
    ///      a future edit to the interface file.
    function swapExactTokensForTokens(
        uint256, /* amountIn */
        uint256, /* amountOutMin */
        address[] calldata path,
        address, /* to */
        uint256 /* deadline */
    )
        external
        returns (uint256[] memory amounts)
    {
        plainVariantCalled = true;
        amounts = new uint256[](path.length);
    }
}

/// @title PancakeSwapAdapterTest
/// @notice Unit tests for {PancakeSwapAdapter} against {MockPancakeRouter} —
///         adapter logic in isolation, no {SettlementEngine} involved.
contract PancakeSwapAdapterTest is Test {
    MockPancakeRouter internal pancakeRouter;
    PancakeSwapAdapter internal adapter;

    MockStable internal tokenIn;
    MockStable internal tokenOut;

    address internal recipient = makeAddr("recipient");

    bytes32 internal constant VENUE_PANCAKE_V2 = keccak256("PANCAKE_V2");

    function setUp() public {
        pancakeRouter = new MockPancakeRouter();
        adapter = new PancakeSwapAdapter(address(pancakeRouter));

        tokenIn = new MockStable("In", "IN", 18);
        tokenOut = new MockStable("Out", "OUT", 18);
    }

    function _order(uint256 amountIn) internal view returns (OrderTypes.Order memory) {
        return OrderTypes.Order({
            account: address(this),
            assetIn: address(tokenIn),
            assetOut: address(tokenOut),
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: VENUE_PANCAKE_V2,
            deadline: block.timestamp + 1 hours
        });
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(PancakeSwapAdapter.InvalidPancakeRouter.selector);
        new PancakeSwapAdapter(address(0));
    }

    /// @dev An EOA passes the zero-address check but holds no code — exactly the
    ///      case {PancakeSwapAdapter}'s NatSpec flags as the dangerous one: it
    ///      would otherwise deploy cleanly and then have every {quote} silently
    ///      return 0 forever, with no error anywhere to explain why.
    function test_ConstructorRevertsOnNonContractAddress() public {
        address eoa = makeAddr("not-a-router");

        vm.expectRevert(PancakeSwapAdapter.InvalidPancakeRouter.selector);
        new PancakeSwapAdapter(eoa);
    }

    /*//////////////////////////////////////////////////////////////
                                  QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_QuoteReturnsExpectedOutputForValidPair() public {
        pancakeRouter.setAmountOut(500e18);

        uint256 amountOut = adapter.quote(address(tokenIn), address(tokenOut), 1000e18);

        assertEq(amountOut, 500e18, "quote did not report the router's configured output");
    }

    /// @dev A real router's {IPancakeRouter02.getAmountsOut} REVERTS when no pair
    ///      exists for the path — it does not return zero. The adapter's
    ///      try/catch is what converts that into the "skip this venue" answer
    ///      Router's best-execution loop expects.
    function test_QuoteReturnsZeroWhenPairDoesNotExist() public {
        pancakeRouter.setQuoteReverts(true);

        uint256 amountOut = adapter.quote(address(tokenIn), address(tokenOut), 1000e18);

        assertEq(amountOut, 0, "a reverting quote must surface as zero, not propagate");
    }

    function test_QuoteReturnsZeroForZeroAmountIn() public {
        pancakeRouter.setAmountOut(500e18);

        uint256 amountOut = adapter.quote(address(tokenIn), address(tokenOut), 0);

        assertEq(amountOut, 0, "zero amountIn must short-circuit to zero");
    }

    function test_QuoteReturnsZeroForIdenticalAssets() public {
        pancakeRouter.setAmountOut(500e18);

        uint256 amountOut = adapter.quote(address(tokenIn), address(tokenIn), 1000e18);

        assertEq(amountOut, 0, "assetIn == assetOut has no pair by construction");
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAP
    //////////////////////////////////////////////////////////////*/

    function test_SwapDeliversMeasuredOutputToRecipient() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        pancakeRouter.setAmountOut(amountOut);
        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(pancakeRouter), amountOut);

        uint256 delivered = adapter.swap(_order(amountIn), recipient);

        assertEq(delivered, amountOut, "returned amountOut must match what actually moved");
        assertEq(tokenOut.balanceOf(recipient), amountOut, "recipient did not receive the measured output");
        assertEq(tokenIn.balanceOf(address(adapter)), 0, "adapter must not retain the funded input");
    }

    function test_SwapUsesSupportingFeeOnTransferVariant() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        pancakeRouter.setAmountOut(amountOut);
        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(pancakeRouter), amountOut);

        adapter.swap(_order(amountIn), recipient);

        assertTrue(pancakeRouter.supportingFeeVariantCalled(), "adapter must call the fee-on-transfer variant");
        assertFalse(pancakeRouter.plainVariantCalled(), "adapter must never reach the plain variant");
    }

    function test_SwapPassesAmountOutMinZero() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        pancakeRouter.setAmountOut(amountOut);
        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(pancakeRouter), amountOut);

        adapter.swap(_order(amountIn), recipient);

        assertEq(pancakeRouter.lastAmountOutMin(), 0, "slippage policy belongs to SettlementEngine alone");
    }

    function test_SwapApprovesExactAmountThenResetsToZero() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;

        pancakeRouter.setAmountOut(amountOut);
        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(pancakeRouter), amountOut);

        adapter.swap(_order(amountIn), recipient);

        assertEq(pancakeRouter.lastAllowanceSeen(), amountIn, "router must see exactly order.amountIn approved");
        assertEq(tokenIn.allowance(address(adapter), address(pancakeRouter)), 0, "approval must be reset after use");
    }

    /// @dev Same donation-resistance property required of every adapter in this
    ///      system: `order.amountIn` is executed exactly, and anything already
    ///      sitting at the adapter's address — a prior settlement's residue, or a
    ///      donation from anyone at all — is left untouched.
    function test_SwapWithPreExistingDonation_DoesNotSweepDonation() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 500e18;
        uint256 donation = 777e18;

        pancakeRouter.setAmountOut(amountOut);
        tokenIn.mint(address(adapter), amountIn + donation);
        tokenOut.mint(address(pancakeRouter), amountOut);

        adapter.swap(_order(amountIn), recipient);

        assertEq(tokenIn.balanceOf(address(adapter)), donation, "donation must survive the swap untouched");
    }

    /// @dev No try/catch on the swap path: a reverting venue must take the whole
    ///      settlement down with it, per A4's full-revert-on-failed-leg
    ///      principle. Only {quote} is required to degrade gracefully.
    function test_SwapRevertsWhenRouterReverts() public {
        uint256 amountIn = 1000e18;

        pancakeRouter.setSwapReverts(true);
        tokenIn.mint(address(adapter), amountIn);

        vm.expectRevert("MockPancakeRouter: forced revert");
        adapter.swap(_order(amountIn), recipient);
    }
}

/// @title PancakeSwapAdapterFullStackTest
/// @notice PROOF THAT {PancakeSwapAdapter} SATISFIES THE SAME CONTRACT EVERY
///         OTHER ADAPTER IN THIS SYSTEM ALREADY DOES. Routes a real buy and a
///         real sell through Safe -> TradingModule -> Router -> SettlementEngine
///         -> {PancakeSwapAdapter} -> {MockPancakeRouter}, and re-runs the same
///         custody assertions A4/A5 already established against the other
///         adapters in this system.
/// @dev The multiplier is never moved in this suite, so every share<->token
///      conversion below is lossless (`amountToShares(x) == x` at
///      `multiplier == MULTIPLIER_SCALE`) and the expected fee/net figures can be
///      computed directly from {SettlementEngine}'s own `FEE_BPS` /
///      `BPS_DENOMINATOR`, exactly as {test/integration/PrimaryRouting.t.sol}
///      does, rather than hardcoded.
contract PancakeSwapAdapterFullStackTest is Test, SafeDeployer {
    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal feeTo = makeAddr("feeTo");

    MockShareRegistry internal shareRegistry;
    MockRebasingEquityToken internal equity;
    MockStable internal stable;

    VenueRegistry internal venues;
    SettlementEngine internal engine;
    Router internal router;

    MockPancakeRouter internal pancakeRouter;
    PancakeSwapAdapter internal adapter;

    address internal safe;
    TradingModule internal module;

    bytes32 internal constant VENUE_PANCAKE_V2 = keccak256("PANCAKE_V2");

    uint256 internal constant CUSTODIED = 1e40;
    uint256 internal constant SHARE_CAP = 1_000_000e18;
    uint256 internal constant STABLE_ALLOWANCE = 1_000_000e18;
    uint256 internal constant SHARE_ALLOWANCE = 1_000_000e18;

    struct Custody {
        uint256 engineIn;
        uint256 engineOut;
        uint256 engineShares;
        uint256 adapterAssetInBalance;
    }

    function setUp() public {
        stable = new MockStable("Stable", "USD", 18);

        vm.startPrank(admin);
        shareRegistry = new MockShareRegistry(admin);
        equity = new MockRebasingEquityToken("Equity", "EQ", admin, IShareRegistry(address(shareRegistry)));
        shareRegistry.registerToken(address(equity));
        shareRegistry.setCustodiedShares(address(equity), CUSTODIED);
        equity.grantRole(equity.PRIMARY_ROLE(), admin);

        venues = new VenueRegistry(admin);
        engine = new SettlementEngine(admin, venues, feeTo);
        router = new Router(venues, engine);
        engine.initializeRouter(address(router));
        engine.registerRebasingToken(address(equity), true);

        pancakeRouter = new MockPancakeRouter();
        adapter = new PancakeSwapAdapter(address(pancakeRouter));
        venues.setAdapter(VENUE_PANCAKE_V2, address(adapter));

        // Fund the venue so it can pay out either leg, exactly as a real
        // PancakeSwap pool would hold reserves of both assets.
        equity.mint(address(pancakeRouter), 1e30);
        vm.stopPrank();

        stable.mint(address(pancakeRouter), 1e30);

        address[] memory owners = new address[](1);
        owners[0] = owner;
        safe = deploySafe(owners, 1);

        module = new TradingModule(safe, address(router));
        enableModule(safe, address(module), owner);

        execAsOwner(
            safe, address(module), abi.encodeCall(TradingModule.setApprovedEngine, (address(engine), true)), owner
        );
        execAsOwner(
            safe,
            address(module),
            abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), SHARE_CAP)),
            owner
        );
        execAsOwner(
            safe,
            address(module),
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(stable), STABLE_ALLOWANCE)),
            owner
        );
        execAsOwner(safe, address(module), abi.encodeCall(TradingModule.setOperator, (operator, true)), owner);

        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), SHARE_ALLOWANCE);

        vm.prank(admin);
        equity.mint(safe, 10_000e18);
        stable.mint(safe, 10_000e18);
    }

    function _order(address assetIn, address assetOut, uint256 amountIn)
        internal
        view
        returns (OrderTypes.Order memory)
    {
        return OrderTypes.Order({
            account: safe,
            assetIn: assetIn,
            assetOut: assetOut,
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: VENUE_PANCAKE_V2,
            deadline: block.timestamp + 1 hours
        });
    }

    function _submitAsOperator(OrderTypes.Order memory o) internal returns (uint256) {
        vm.prank(operator);
        return module.submitOrder(o);
    }

    function _snapshot(address assetIn, address assetOut) internal view returns (Custody memory c) {
        c.engineIn = IERC20(assetIn).balanceOf(address(engine));
        c.engineOut = IERC20(assetOut).balanceOf(address(engine));
        c.engineShares = equity.shares(address(engine));
        c.adapterAssetInBalance = IERC20(assetIn).balanceOf(address(adapter));
    }

    /// @dev A4/A5's custody post-condition, re-run against THIS adapter: the
    ///      engine retained nothing, and the adapter's input holding returned to
    ///      its pre-settlement level (here, exactly zero on both legs, since
    ///      neither leg leaves a donation behind).
    function _assertCustodyUnchanged(Custody memory before, address assetIn, address assetOut) internal view {
        assertEq(IERC20(assetIn).balanceOf(address(engine)), before.engineIn, "engine assetIn delta");
        assertEq(IERC20(assetOut).balanceOf(address(engine)), before.engineOut, "engine assetOut delta");
        assertEq(equity.shares(address(engine)), before.engineShares, "engine share delta");
        assertEq(IERC20(assetIn).balanceOf(address(adapter)), before.adapterAssetInBalance, "adapter assetIn delta");
    }

    /// @notice Routes a real buy and a real sell through the entire stack against
    ///         {PancakeSwapAdapter}, and confirms every A4/A5 custody invariant
    ///         holds exactly as it does against the AMM mock elsewhere in this
    ///         suite — this is the proof that the PancakeSwap venue satisfies the
    ///         same contract as every other adapter in this system.
    function test_AdapterSatisfiesSettlementEngineRetentionCheck() public {
        /*--------------------------------------------------------------------
                                        BUY
        --------------------------------------------------------------------*/
        uint256 buyAmountIn = 1_000e18;
        uint256 buyGrossEquityOut = 900e18;
        pancakeRouter.setAmountOut(buyGrossEquityOut);

        uint256 safeSharesBeforeBuy = equity.shares(safe);
        uint256 feeToSharesBeforeBuy = equity.shares(feeTo);
        Custody memory beforeBuy = _snapshot(address(stable), address(equity));

        _submitAsOperator(_order(address(stable), address(equity), buyAmountIn));

        _assertCustodyUnchanged(beforeBuy, address(stable), address(equity));

        // Lossless at multiplier == MULTIPLIER_SCALE: grossShares == the token
        // figure the venue paid out.
        uint256 grossShares = equity.amountToShares(buyGrossEquityOut);
        uint256 feeShares = (grossShares * engine.FEE_BPS()) / engine.BPS_DENOMINATOR();
        uint256 netShares = grossShares - feeShares;

        assertEq(equity.shares(safe) - safeSharesBeforeBuy, netShares, "client did not receive net shares");
        assertEq(equity.shares(feeTo) - feeToSharesBeforeBuy, feeShares, "fee recipient did not receive fee shares");

        /*--------------------------------------------------------------------
                                        SELL
        --------------------------------------------------------------------*/
        uint256 sellAmountIn = 500e18;
        uint256 sellGrossStableOut = 480e18;
        pancakeRouter.setAmountOut(sellGrossStableOut);

        uint256 safeSharesBeforeSell = equity.shares(safe);
        uint256 safeStableBeforeSell = stable.balanceOf(safe);
        uint256 feeToStableBeforeSell = stable.balanceOf(feeTo);
        Custody memory beforeSell = _snapshot(address(equity), address(stable));

        _submitAsOperator(_order(address(equity), address(stable), sellAmountIn));

        _assertCustodyUnchanged(beforeSell, address(equity), address(stable));

        uint256 sharesIn = equity.amountToShares(sellAmountIn);
        uint256 feeAmount = (sellGrossStableOut * engine.FEE_BPS()) / engine.BPS_DENOMINATOR();
        uint256 netOut = sellGrossStableOut - feeAmount;

        assertEq(safeSharesBeforeSell - equity.shares(safe), sharesIn, "client was not debited the resolved shares");
        assertEq(stable.balanceOf(safe) - safeStableBeforeSell, netOut, "client did not receive net stable");
        assertEq(stable.balanceOf(feeTo) - feeToStableBeforeSell, feeAmount, "fee recipient did not receive fee");
    }
}
