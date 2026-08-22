// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {Router} from "../../src/core/Router.sol";
import {SettlementEngine} from "../../src/core/SettlementEngine.sol";
import {IRebasingEquityToken} from "../../src/interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../../src/interfaces/IShareRegistry.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../../src/mocks/MockShareRegistry.sol";
import {MockStable} from "../../src/mocks/MockStable.sol";
import {VenueRegistry} from "../../src/router/VenueRegistry.sol";

import {MockAdapter} from "../mocks/SettlementMocks.sol";

/// @title SettlementHandler
/// @notice Bounded action surface for the settlement invariant run.
/// @dev EVERY ACTION MUST SUCCEED OR RETURN EARLY. `fail_on_revert = true` is set
///      for invariant runs in foundry.toml, so a handler that lets a call revert
///      fails the whole run rather than skipping that case. Preconditions are
///      therefore checked before acting, never asserted after.
///
///      ============ WHY FEE RECIPIENTS NEVER TRADE ============
///      The fee-recipient candidates are a CLOSED SET, disjoint from the trading
///      actors, and no action ever makes one of them trade, transfer, or receive
///      anything except a fee. That constraint is what makes INV 5 checkable: it
///      compares cumulative fee shares against the SUM OF BALANCES across every
///      address that has ever been fee recipient, and a recipient that also
///      traded would move its own balance for reasons unrelated to fees, making
///      the invariant false for entirely legitimate reasons.
///
///      If a future action lets a fee recipient trade, INV 5 must be reformulated
///      (e.g. against per-address ghost deltas), not deleted.
///      ========================================================
contract SettlementHandler is Test {
    MockStable public stable;
    MockRebasingEquityToken public equity;
    Router public router;
    SettlementEngine public engine;
    MockAdapter public adapter;
    address public admin;
    bytes32 public venueId;

    address[3] public actors;
    address[3] public feeCandidates;

    // ---- ghosts ----
    uint256 public ghostFeeSharesCollected;
    address[] public historicalFeeRecipients;
    mapping(address => bool) public isHistoricalFeeRecipient;

    /// @dev Baselines for the delta-based custody invariant. Raised by {donate},
    ///      never by a settlement — which is exactly what INV 3 asserts.
    uint256 public engineStableBaseline;
    uint256 public engineShareBaseline;

    uint256 public buyCount;
    uint256 public sellCount;
    uint256 public rebaseCount;
    uint256 public feeRecipientChanges;
    uint256 public donationCount;

    uint256 internal constant MULTIPLIER_CAP = 1e26;

    constructor(
        MockStable stable_,
        MockRebasingEquityToken equity_,
        Router router_,
        SettlementEngine engine_,
        MockAdapter adapter_,
        address admin_,
        bytes32 venueId_,
        address[3] memory actors_,
        address[3] memory feeCandidates_
    ) {
        stable = stable_;
        equity = equity_;
        router = router_;
        engine = engine_;
        adapter = adapter_;
        admin = admin_;
        venueId = venueId_;
        actors = actors_;
        feeCandidates = feeCandidates_;

        _recordFeeRecipient(engine_.feeRecipient());
    }

    function _recordFeeRecipient(address r) internal {
        if (!isHistoricalFeeRecipient[r]) {
            isHistoricalFeeRecipient[r] = true;
            historicalFeeRecipients.push(r);
        }
    }

    function historicalFeeRecipientCount() external view returns (uint256) {
        return historicalFeeRecipients.length;
    }

    function _order(address actor, address assetIn, address assetOut, uint256 amountIn)
        internal
        view
        returns (OrderTypes.Order memory)
    {
        return OrderTypes.Order({
            account: actor,
            assetIn: assetIn,
            assetOut: assetOut,
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: venueId,
            deadline: block.timestamp + 1 days
        });
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function buy(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];

        // Floor: large enough that the input resolves to shares and the net
        // survives the fee. Ceiling: bounded by what the actor holds and what the
        // adapter can pay out.
        uint256 floorAmt = equity.sharesToAmount(1e9) + 1;
        uint256 ceilAmt = stable.balanceOf(actor);
        uint256 adapterStock = equity.balanceOf(address(adapter));
        if (adapterStock < ceilAmt) ceilAmt = adapterStock;
        if (ceilAmt > 1e24) ceilAmt = 1e24;
        if (ceilAmt <= floorAmt) return;

        uint256 amountIn = bound(amountSeed, floorAmt, ceilAmt);
        if (equity.amountToShares(amountIn) == 0) return;

        address feeRecipient = engine.feeRecipient();
        uint256 feeBefore = equity.shares(feeRecipient);

        vm.prank(actor);
        router.submitOrder(_order(actor, address(stable), address(equity), amountIn));

        // The recipient never trades, so its whole delta is fee revenue.
        ghostFeeSharesCollected += equity.shares(feeRecipient) - feeBefore;
        ++buyCount;
    }

    function sell(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];

        uint256 floorAmt = equity.sharesToAmount(1e9) + 1;
        uint256 ceilAmt = equity.balanceOf(actor);
        if (ceilAmt > 1e24) ceilAmt = 1e24;
        if (ceilAmt <= floorAmt) return;

        uint256 amountIn = bound(amountSeed, floorAmt, ceilAmt);

        uint256 sharesIn = equity.amountToShares(amountIn);
        if (sharesIn == 0) return;
        uint256 executable = equity.sharesToAmount(sharesIn);
        if (executable == 0) return;
        // The adapter must be able to deliver the stable leg.
        if (stable.balanceOf(address(adapter)) < executable) return;

        vm.prank(actor);
        router.submitOrder(_order(actor, address(equity), address(stable), amountIn));
        ++sellCount;
    }

    /// @dev Up-only, so the new multiplier is always strictly above the current
    ///      one. Capped so repeated actions cannot inflate it until token amounts
    ///      overflow and start reverting for reasons unrelated to the engine.
    function corporateAction(uint256 seed) external {
        uint256 current = equity.multiplier();
        if (current >= MULTIPLIER_CAP) return;

        uint256 ceiling = current + (current / 4) + 1;
        if (ceiling > MULTIPLIER_CAP) ceiling = MULTIPLIER_CAP;
        uint256 next = bound(seed, current + 1, ceiling);

        vm.prank(admin);
        equity.applyCorporateAction(next);
        ++rebaseCount;
    }

    /// @dev A FUZZABLE ACTION on purpose. Without it the multi-recipient path is
    ///      dead code in every run, and INV 5's "every address that has EVER been
    ///      fee recipient" clause would never be exercised against more than one.
    function changeFeeRecipient(uint256 seed) external {
        address next = feeCandidates[seed % feeCandidates.length];
        if (next == engine.feeRecipient()) return;

        vm.prank(admin);
        engine.setFeeRecipient(next);
        _recordFeeRecipient(next);
        ++feeRecipientChanges;
    }

    /// @dev Unsolicited transfers into the engine. Present so INV 3 has to be a
    ///      DELTA check: with donations in the mix, an absolute-zero custody
    ///      invariant would be false from the first donation onward.
    function donate(uint256 seed, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e20);

        if (seed % 2 == 0) {
            stable.mint(address(engine), amount);
            engineStableBaseline += amount;
        } else {
            vm.prank(admin);
            equity.mint(address(engine), amount);
            engineShareBaseline += amount;
        }
        ++donationCount;
    }
}

/// @title SettlementInvariantTest
/// @notice Handler-based invariants over the full Router -> Engine -> Adapter path.
contract SettlementInvariantTest is Test {
    address internal admin = makeAddr("admin");
    address internal sink = makeAddr("sink");

    MockStable internal stable;
    MockShareRegistry internal shareRegistry;
    MockRebasingEquityToken internal equity;
    VenueRegistry internal venues;
    SettlementEngine internal engine;
    Router internal router;
    MockAdapter internal adapter;
    SettlementHandler internal handler;

    bytes32 internal constant VENUE = keccak256("MOCK_VENUE");

    address[3] internal actors;
    address[3] internal feeCandidates;

    /// @dev INV 4's running high-water mark.
    uint256 internal lastSeenMultiplier;

    function setUp() public {
        actors = [makeAddr("actorA"), makeAddr("actorB"), makeAddr("actorC")];
        feeCandidates = [makeAddr("feeA"), makeAddr("feeB"), makeAddr("feeC")];

        stable = new MockStable("Stable", "USD", 18);

        vm.startPrank(admin);
        shareRegistry = new MockShareRegistry(admin);
        equity = new MockRebasingEquityToken("Equity", "EQ", admin, IShareRegistry(address(shareRegistry)));
        shareRegistry.registerToken(address(equity));
        shareRegistry.setCustodiedShares(address(equity), 1e33);
        equity.grantRole(equity.PRIMARY_ROLE(), admin);
        equity.grantRole(equity.CORPORATE_ACTION_ROLE(), admin);

        venues = new VenueRegistry(admin);
        engine = new SettlementEngine(admin, venues, feeCandidates[0]);
        router = new Router(venues, engine);
        engine.initializeRouter(address(router));
        engine.registerRebasingToken(address(equity), true);

        adapter = new MockAdapter(sink, IRebasingEquityToken(address(equity)));
        venues.setAdapter(VENUE, address(adapter));

        equity.mint(address(adapter), 1e26);
        for (uint256 i; i < actors.length; ++i) {
            equity.mint(actors[i], 1e24);
        }
        vm.stopPrank();

        stable.mint(address(adapter), 1e30);
        for (uint256 i; i < actors.length; ++i) {
            stable.mint(actors[i], 1e26);
            vm.startPrank(actors[i]);
            stable.approve(address(engine), type(uint256).max);
            equity.approve(address(engine), type(uint256).max);
            vm.stopPrank();
        }

        handler = new SettlementHandler(stable, equity, router, engine, adapter, admin, VENUE, actors, feeCandidates);

        // The handler mints donations and drives corporate actions on the admin's
        // behalf via prank, so it needs no roles of its own.
        lastSeenMultiplier = equity.multiplier();

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice INV 1 — every share in issue is backed by an allocated share unit.
    function invariant_TotalSharesMatchRegistryAllocation() public view {
        assertEq(
            equity.totalShares(),
            shareRegistry.allocatedShares(address(equity)),
            "INV1: totalShares != registry allocation"
        );
    }

    /// @notice INV 2 — shares are conserved: the holders account for the total,
    ///         exactly, with no dust and no leakage.
    /// @dev The address set is closed by construction: shares are created only by
    ///      mint (to actors, the adapter, and the engine via {donate}) and move
    ///      only between the addresses below.
    function invariant_ShareSumEqualsTotalShares() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += equity.shares(actors[i]);
        }
        for (uint256 i; i < feeCandidates.length; ++i) {
            sum += equity.shares(feeCandidates[i]);
        }
        sum += equity.shares(address(adapter));
        sum += equity.shares(sink);
        sum += equity.shares(address(engine));
        sum += equity.shares(address(router));
        sum += equity.shares(address(handler));

        assertEq(sum, equity.totalShares(), "INV2: share sum != totalShares");
    }

    /// @notice INV 3 — the engine retains nothing from any settlement.
    /// @dev DELTA-BASED, not absolute zero. The handler donates to the engine, and
    ///      those donations are permanently stranded because there is no rescue
    ///      path by design — so the correct assertion is that the engine's holdings
    ///      equal the DONATED baseline, never that they are zero.
    function invariant_EngineRetainsNothingFromSettlements() public view {
        assertEq(stable.balanceOf(address(engine)), handler.engineStableBaseline(), "INV3: engine retained stable");
        assertEq(equity.shares(address(engine)), handler.engineShareBaseline(), "INV3: engine retained shares");
    }

    /// @notice INV 4 — the multiplier never decreases.
    function invariant_MultiplierMonotonicallyNonDecreasing() public {
        uint256 current = equity.multiplier();
        assertGe(current, lastSeenMultiplier, "INV4: multiplier decreased");
        lastSeenMultiplier = current;
    }

    /// @notice INV 5 — every fee share collected on a buy is still held by some
    ///         address that has been the fee recipient at some point.
    /// @dev THE HISTORICAL SET IS THE POINT. Summing only the CURRENT recipient
    ///      would silently break the moment {changeFeeRecipient} fires, because the
    ///      previous recipient keeps the shares it was already paid. Ghost-tracking
    ///      every address that has ever held the role is what makes the invariant
    ///      survive a rotation. Holds only because fee recipients never trade — see
    ///      the note on {SettlementHandler}.
    function invariant_FeeSharesFullyAccountedAcrossAllRecipients() public view {
        uint256 held;
        uint256 n = handler.historicalFeeRecipientCount();
        for (uint256 i; i < n; ++i) {
            held += equity.shares(handler.historicalFeeRecipients(i));
        }
        assertEq(held, handler.ghostFeeSharesCollected(), "INV5: fee shares unaccounted for");
    }

    /// @notice Coverage report for the run, so a vacuously-passing suite is visible.
    function invariant_CallSummary() public view {
        console.log("buys              ", handler.buyCount());
        console.log("sells             ", handler.sellCount());
        console.log("corporate actions ", handler.rebaseCount());
        console.log("fee recipient sets", handler.feeRecipientChanges());
        console.log("donations         ", handler.donationCount());
    }
}
