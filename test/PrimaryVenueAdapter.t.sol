// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TradingModule} from "../src/accounts/TradingModule.sol";
import {Router} from "../src/core/Router.sol";
import {SettlementEngine} from "../src/core/SettlementEngine.sol";
import {IRebasingEquityToken} from "../src/interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {PrimaryReserveVault} from "../src/primary/PrimaryReserveVault.sol";
import {PrimaryVenueAdapter} from "../src/primary/PrimaryVenueAdapter.sol";
import {VenueRegistry} from "../src/router/VenueRegistry.sol";

import {SafeDeployer} from "./helpers/SafeDeployer.sol";
import {MockAdapter, MockStable} from "./mocks/SettlementMocks.sol";

/*//////////////////////////////////////////////////////////////////////////
                        SHARED FIXTURE
//////////////////////////////////////////////////////////////////////////*/

/// @dev Deploys the primary venue and, alongside it, the full A2-A5 stack plus a
///      second (AMM) venue, so best-execution and quote/settlement-consistency
///      tests can run against the real Router and SettlementEngine rather than
///      against a re-implementation of them.
abstract contract PrimaryAdapterFixture is Test, SafeDeployer {
    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal feeTo = makeAddr("feeTo");
    address internal sink = makeAddr("sink");
    address internal recipient = makeAddr("recipient");
    address internal whale = makeAddr("whale");
    address internal donor = makeAddr("donor");
    address internal stranger = makeAddr("stranger");

    /*//////////////////////////////////////////////////////////////
                                 SYSTEM
    //////////////////////////////////////////////////////////////*/

    MockShareRegistry internal shareRegistry;
    MockRebasingEquityToken internal equity;
    MockStable internal stable;
    MockStable internal other;

    PrimaryReserveVault internal vault;
    PrimaryVenueAdapter internal primary;

    VenueRegistry internal venues;
    SettlementEngine internal engine;
    Router internal router;
    MockAdapter internal amm;

    address internal safe;
    TradingModule internal module;

    bytes32 internal constant PRIMARY_VENUE = keccak256("PRIMARY_VENUE");
    bytes32 internal constant AMM_VENUE = keccak256("AMM_VENUE");

    uint256 internal constant WAD = 1e18;

    /// @dev Deliberately vast. Every "shares unavailable" test lowers it
    ///      explicitly, so a registry-backing failure is always the test asking
    ///      for one rather than an accident of sizing.
    uint256 internal constant CUSTODIED = 1e40;

    function _deployAndWire() internal {
        stable = new MockStable("Stable", "USD");
        other = new MockStable("Other", "OTH");

        vm.startPrank(admin);
        shareRegistry = new MockShareRegistry(admin);
        equity = new MockRebasingEquityToken("Equity", "EQ", admin, IShareRegistry(address(shareRegistry)));
        shareRegistry.registerToken(address(equity));
        shareRegistry.setCustodiedShares(address(equity), CUSTODIED);

        equity.grantRole(equity.PRIMARY_ROLE(), admin);
        equity.grantRole(equity.CORPORATE_ACTION_ROLE(), admin);
        vm.stopPrank();

        // ---- the primary venue, wired exactly as the README prescribes ------
        // The vault deploys standalone FIRST: it takes no adapter address, so
        // there is no circular dependency to break.
        vault = new PrimaryReserveVault(IERC20(address(stable)), admin);
        primary = new PrimaryVenueAdapter(address(equity), address(stable), address(vault));

        vm.startPrank(admin);
        equity.grantRole(equity.PRIMARY_ROLE(), address(primary));
        vault.grantRole(vault.ADAPTER_ROLE(), address(primary));
        vm.stopPrank();

        // ---- the rest of the stack, unmodified from A2-A5 --------------------
        vm.startPrank(admin);
        venues = new VenueRegistry(admin);
        engine = new SettlementEngine(admin, venues, feeTo);
        router = new Router(venues, engine);
        engine.initializeRouter(address(router));
        engine.registerRebasingToken(address(equity), true);

        venues.setAdapter(PRIMARY_VENUE, address(primary));

        // Stands in for PancakeSwapAdapter, which is not yet implemented. What
        // the best-execution tests need from it is only that it is a second
        // registered venue with an independently settable quote, which this
        // provides.
        amm = new MockAdapter(sink, IRebasingEquityToken(address(equity)));
        venues.setAdapter(AMM_VENUE, address(amm));

        equity.mint(address(amm), 1e26);
        equity.mint(whale, 1e30);
        vm.stopPrank();

        stable.mint(address(amm), 1e30);

        _deploySafeStack();

        vm.label(address(primary), "primary");
        vm.label(address(vault), "vault");
        vm.label(address(amm), "amm");
        vm.label(address(equity), "equity");
        vm.label(address(stable), "stable");
    }

    function _deploySafeStack() private {
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
            abi.encodeCall(TradingModule.setEngineShareCap, (address(engine), address(equity), 1e34)),
            owner
        );
        execAsOwner(
            safe,
            address(module),
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (address(engine), address(stable), 1e36)),
            owner
        );
        execAsOwner(safe, address(module), abi.encodeCall(TradingModule.setOperator, (operator, true)), owner);

        vm.prank(admin);
        equity.mint(safe, 1e28);
        stable.mint(safe, 1e30);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _rebase(uint256 newMultiplier) internal {
        vm.prank(admin);
        equity.applyCorporateAction(newMultiplier);
    }

    /// @dev Capitalize the vault through its real admin path.
    function _fundVault(uint256 amount) internal {
        stable.mint(admin, amount);

        vm.startPrank(admin);
        stable.approve(address(vault), amount);
        vault.adminDeposit(amount);
        vm.stopPrank();
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
            venueId: PRIMARY_VENUE,
            deadline: block.timestamp + 1 hours
        });
    }

    function _buyOrder(uint256 amountIn) internal view returns (OrderTypes.Order memory) {
        return _order(address(stable), address(equity), amountIn);
    }

    function _sellOrder(uint256 amountIn) internal view returns (OrderTypes.Order memory) {
        return _order(address(equity), address(stable), amountIn);
    }

    /*//////////////////////////////////////////////////////////////
        THE 5-STEP DIRECT-SELL CONSTRUCTION

        EVERY direct (non-full-stack) sell test goes through this helper, and
        the reason is a correctness precondition, not convenience.

        `amountToSharesCeil` is exact ONLY when handed a value that was itself
        produced by FLOORING an integer share quantity at the current
        multiplier — i.e. the engine's `executableAmountIn`. Calling swap()
        with a client's original, unresolved amountIn breaks that precondition
        SILENTLY: at a multiplier that happens to divide cleanly the numbers
        still line up, so such a test passes by coincidence and stops passing
        the moment the multiplier is awkward.

        So the construction is fixed:
          1. choose a target sharesIn
          2. fund the adapter with EXACTLY sharesIn shares via transferShares,
             replicating the engine's transferSharesFrom in its STEP 3
          3. executableAmountIn = sharesToAmount(sharesIn)  [FLOOR]
          4. build the Order with amountIn = executableAmountIn, NEVER the
             original client-facing figure
          5. assert against sharesIn from step 1 as ground truth

        Only FULL-STACK tests may start from a client-facing amountIn, because
        there the engine performs step 3 itself.
    //////////////////////////////////////////////////////////////*/

    /// @dev Steps 2-4. Returns the Order the engine would have handed the adapter.
    function _fundAdapterForSell(uint256 sharesIn) internal returns (OrderTypes.Order memory order) {
        // Step 2 — share-exact funding, exactly as the engine funds an adapter.
        vm.prank(whale);
        equity.transferShares(address(primary), sharesIn);

        // Step 3 — the FLOOR the engine would have applied.
        uint256 executableAmountIn = equity.sharesToAmount(sharesIn);

        // Step 4 — never the original client figure.
        order = _sellOrder(executableAmountIn);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        DIRECT-ADAPTER TESTS
//////////////////////////////////////////////////////////////////////////*/

contract PrimaryVenueAdapterTest is PrimaryAdapterFixture {
    function setUp() public {
        _deployAndWire();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_initialState() public view {
        assertEq(address(primary.equityToken()), address(equity), "equity not wired");
        assertEq(address(primary.stable()), address(stable), "stable not wired");
        assertEq(address(primary.vault()), address(vault), "vault not wired");
        assertEq(address(primary.registry()), address(shareRegistry), "registry not derived from the token");
    }

    function test_revert_constructor_zeroAddresses() public {
        vm.expectRevert(PrimaryVenueAdapter.InvalidAddress.selector);
        new PrimaryVenueAdapter(address(0), address(stable), address(vault));

        vm.expectRevert(PrimaryVenueAdapter.InvalidAddress.selector);
        new PrimaryVenueAdapter(address(equity), address(0), address(vault));

        vm.expectRevert(PrimaryVenueAdapter.InvalidAddress.selector);
        new PrimaryVenueAdapter(address(equity), address(stable), address(0));
    }

    /// @dev An EOA passes a zero-check and then makes every quote return 0 for
    ///      reasons no error would explain. The code check is the one that
    ///      catches a real deploy-script mistake.
    function test_revert_constructor_rejectsAddressWithoutCode() public {
        vm.expectRevert(PrimaryVenueAdapter.InvalidAddress.selector);
        new PrimaryVenueAdapter(stranger, address(stable), address(vault));

        vm.expectRevert(PrimaryVenueAdapter.InvalidAddress.selector);
        new PrimaryVenueAdapter(address(equity), stranger, address(vault));

        vm.expectRevert(PrimaryVenueAdapter.InvalidAddress.selector);
        new PrimaryVenueAdapter(address(equity), address(stable), stranger);
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY PATH — BUY (DIRECT)
    //////////////////////////////////////////////////////////////*/

    function test_BuyMintsSharesAtPar() public {
        uint256 amountIn = 1_000e18;

        // The adapter's stable balance BEFORE any funding. This is the level the
        // engine's STEP 5 check requires it to return to.
        uint256 adapterStableBefore = stable.balanceOf(address(primary));
        uint256 vaultBefore = vault.reserveBalance();
        uint256 recipientSharesBefore = equity.shares(recipient);
        uint256 expectedShares = equity.amountToShares(amountIn);

        // Pre-fund, exactly as the engine does in its STEP 3.
        stable.mint(address(primary), amountIn);

        primary.swap(_buyOrder(amountIn), recipient);

        assertEq(equity.shares(recipient) - recipientSharesBefore, expectedShares, "recipient shares != amountToShares");
        assertEq(vault.reserveBalance() - vaultBefore, amountIn, "vault did not receive exactly amountIn");
        assertEq(stable.balanceOf(address(primary)), adapterStableBefore, "adapter retained stable");
    }

    function test_BuyMintsSharesAtPar_atNonUnityMultiplier() public {
        _rebase(1.333e18);

        uint256 amountIn = 1_000e18;
        uint256 expectedShares = equity.amountToShares(amountIn);

        stable.mint(address(primary), amountIn);
        primary.swap(_buyOrder(amountIn), recipient);

        assertEq(equity.shares(recipient), expectedShares, "shares minted at the wrong multiplier");
        assertEq(vault.reserveBalance(), amountIn, "vault did not receive exactly amountIn");
        assertEq(stable.balanceOf(address(primary)), 0, "adapter retained stable");
    }

    function test_BuyAllocatesRegistryBackingExactly() public {
        uint256 amountIn = 500e18;
        uint256 allocatedBefore = shareRegistry.allocatedShares(address(equity));
        uint256 expectedShares = equity.amountToShares(amountIn);

        stable.mint(address(primary), amountIn);
        primary.swap(_buyOrder(amountIn), recipient);

        assertEq(
            shareRegistry.allocatedShares(address(equity)) - allocatedBefore,
            expectedShares,
            "registry allocation diverged from shares minted"
        );
    }

    function test_event_BuyEmitsPrimaryMint() public {
        uint256 amountIn = 250e18;
        uint256 expectedShares = equity.amountToShares(amountIn);

        stable.mint(address(primary), amountIn);

        vm.expectEmit(true, true, true, true, address(primary));
        emit PrimaryVenueAdapter.PrimaryMint(recipient, expectedShares, amountIn);

        primary.swap(_buyOrder(amountIn), recipient);
    }

    /// @dev A buy too small to resolve to a single share. Rejected loudly rather
    ///      than minting zero and reporting success.
    function test_revert_BuyRoundingToZeroShares() public {
        _rebase(1_000e18);

        // 1 wei of stable buys floor(1 * 1e18 / 1000e18) == 0 shares.
        stable.mint(address(primary), 1);

        vm.expectRevert(PrimaryVenueAdapter.ZeroAmount.selector);
        primary.swap(_buyOrder(1), recipient);
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY PATH — SELL (DIRECT)
    //////////////////////////////////////////////////////////////*/

    function test_SellRedeemsSharesAtPar() public {
        _rebase(1.333e18);
        _fundVault(1e24);

        // Step 1 — the ground truth for every assertion below.
        uint256 sharesIn = 7_777_777_777_777_777;

        // Steps 2-4.
        OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);

        uint256 expectedPayout = equity.sharesToAmount(sharesIn);
        uint256 vaultBefore = vault.reserveBalance();
        uint256 recipientBefore = stable.balanceOf(recipient);

        // Step 5.
        uint256 amountOut = primary.swap(order, recipient);

        assertEq(amountOut, expectedPayout, "reported amountOut != floored par value");
        assertEq(stable.balanceOf(recipient) - recipientBefore, expectedPayout, "recipient paid the wrong amount");
        assertEq(vaultBefore - vault.reserveBalance(), expectedPayout, "vault outflow != payout");
        assertEq(equity.shares(address(primary)), 0, "adapter retained shares");
    }

    function test_SellReleasesRegistryBackingExactly() public {
        _rebase(1.333e18);
        _fundVault(1e24);

        uint256 sharesIn = 3_333_333_333_333_333;
        OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);

        uint256 allocatedBefore = shareRegistry.allocatedShares(address(equity));

        primary.swap(order, recipient);

        // The check that would catch a silent divergence between the share
        // quantity burned and the backing released.
        assertEq(
            allocatedBefore - shareRegistry.allocatedShares(address(equity)),
            sharesIn,
            "registry release diverged from shares burned"
        );
    }

    function test_event_SellEmitsPrimaryRedeem() public {
        _rebase(1.5e18);
        _fundVault(1e24);

        uint256 sharesIn = 1_001;
        OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);
        uint256 expectedPayout = equity.sharesToAmount(sharesIn);

        vm.expectEmit(true, true, true, true, address(primary));
        emit PrimaryVenueAdapter.PrimaryRedeem(recipient, sharesIn, expectedPayout);

        primary.swap(order, recipient);
    }

    /// @dev The ceiling inverse recovers `sharesIn` EXACTLY across a table of
    ///      awkward multipliers — the property the whole sell path rests on.
    function test_SellRecoversEngineResolvedSharesExactly() public {
        _fundVault(1e30);

        // Up-only, so walked in increasing order.
        uint256[5] memory multipliers = [WAD + 1, 1.333e18, 2.5e18, 7e18, 1e24];
        uint256[4] memory shareTable = [uint256(1), 3, 999_999_999_999_999_999, 1e21 + 7];

        for (uint256 i; i < multipliers.length; ++i) {
            _rebase(multipliers[i]);

            for (uint256 j; j < shareTable.length; ++j) {
                uint256 sharesIn = shareTable[j];
                OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);

                vm.recordLogs();
                primary.swap(order, recipient);

                assertEq(equity.shares(address(primary)), 0, "adapter did not return to zero shares");
                assertEq(_lastRedeemShares(), sharesIn, "ceiling inverse did not recover sharesIn exactly");
            }
        }
    }

    /// @dev Reads `sharesBurned` out of the most recent {PrimaryRedeem}. Used
    ///      where the burned quantity is the thing under test and asserting it
    ///      via a balance would be indirect.
    function _lastRedeemShares() private returns (uint256 sharesBurned) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = PrimaryVenueAdapter.PrimaryRedeem.selector;

        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == address(primary) && log.topics.length > 0 && log.topics[0] == topic) {
                (, sharesBurned,) = abi.decode(log.data, (address, uint256, uint256));
                return sharesBurned;
            }
        }
        fail();
    }

    /// @dev The ONLY value that reaches this guard is `amountIn == 0`, because
    ///      `ceil(x * 1e18 / m)` is at least 1 for every `x >= 1` — the ceiling
    ///      inverse cannot round a nonzero amount down to nothing the way the
    ///      floor conversion on the buy side can.
    ///
    ///      So the guard exists for a DIRECT caller, not for the engine: the
    ///      engine rejects a zero `amountIn` in its own STEP 2 before any adapter
    ///      is reached. Anyone may call {swap}, so the unreachable-via-engine
    ///      path is still reachable, and it fails loudly rather than redeeming
    ///      zero shares and reporting success.
    function test_revert_SellWithZeroAmountIn() public {
        _fundVault(1e24);

        vm.expectRevert(PrimaryVenueAdapter.ZeroAmount.selector);
        primary.swap(_sellOrder(0), recipient);
    }

    function test_revert_SellWithInsufficientVaultReserve() public {
        _rebase(2e18);
        // Vault deliberately left empty.

        uint256 sharesIn = 1_000e18;
        OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);

        vm.expectRevert(PrimaryVenueAdapter.InsufficientReserve.selector);
        primary.swap(order, recipient);
    }

    /*//////////////////////////////////////////////////////////////
                          UNSUPPORTED PAIRS
    //////////////////////////////////////////////////////////////*/

    /// @dev {swap} reverts where {quote} returns 0. A quote is a question and 0
    ///      is a valid answer; a swap is an instruction, and returning 0 would
    ///      let a caller believe a trade settled.
    function test_revert_SwapUnsupportedAssetPair() public {
        vm.expectRevert(PrimaryVenueAdapter.UnsupportedAssetPair.selector);
        primary.swap(_order(address(other), address(stable), 1e18), recipient);

        vm.expectRevert(PrimaryVenueAdapter.UnsupportedAssetPair.selector);
        primary.swap(_order(address(stable), address(other), 1e18), recipient);

        vm.expectRevert(PrimaryVenueAdapter.UnsupportedAssetPair.selector);
        primary.swap(_order(address(stable), address(stable), 1e18), recipient);

        vm.expectRevert(PrimaryVenueAdapter.UnsupportedAssetPair.selector);
        primary.swap(_order(address(equity), address(equity), 1e18), recipient);
    }

    /*//////////////////////////////////////////////////////////////
                      QUOTE — GRACEFUL DEGRADATION

        Every unmet precondition returns 0, never a revert. Router treats 0 and
        a revert identically (skip the venue), so the two are equivalent to the
        caller — but 0 is cheaper, and it keeps a genuinely broken adapter
        distinguishable from a correctly-unfillable one in Router's `catch`.
    //////////////////////////////////////////////////////////////*/

    function test_QuoteReturnsZeroWhenSharesUnavailable() public {
        // Drive availableShares to exactly zero by allocating everything the
        // registry records, through the real mint path.
        uint256 available = shareRegistry.availableShares(address(equity));

        vm.prank(admin);
        equity.mint(whale, available);

        assertEq(shareRegistry.availableShares(address(equity)), 0, "backing not exhausted");

        assertEq(primary.quote(address(stable), address(equity), 1_000e18), 0, "quote should be 0 with no backing");
    }

    /// @dev Partial exhaustion: enough backing for a small buy, not enough for a
    ///      large one. Proves the check is against the requested quantity rather
    ///      than a flat "any backing at all" test.
    function test_QuoteReturnsZeroOnlyWhenRequestExceedsAvailableShares() public {
        uint256 available = shareRegistry.availableShares(address(equity));

        vm.prank(admin);
        equity.mint(whale, available - 1_000e18);

        assertEq(shareRegistry.availableShares(address(equity)), 1_000e18, "wrong remaining backing");

        assertGt(primary.quote(address(stable), address(equity), 1_000e18), 0, "exactly-fillable buy quoted 0");
        assertEq(primary.quote(address(stable), address(equity), 1_000e18 + 1), 0, "over-sized buy should quote 0");
    }

    /*//////////////////////////////////////////////////////////////
        NO ATTESTATION-FRESHNESS TEST — AND WHY

        The Part B specification for this adapter called for a
        `registry.isAttestationFresh(equityToken)` check in the buy quote, and
        a matching `test_QuoteReturnsZeroWhenAttestationStale`.

        NEITHER EXISTS, because the thing they would test does not exist.
        {MockShareRegistry} has no attestation layer at all: no attestation
        timestamp, no staleness bound, no `isAttestationFresh`, and no
        `StaleAttestation` error. That is deliberate and documented on the
        registry itself — custody attestation and freshness are the OTHER Part
        B option ("Proof of Collateral"), and this submission implements
        Primary vs Secondary Routing instead.

        Writing the test would have required first adding an attestation layer
        to a Part A contract that explicitly documents its absence as
        intentional, which is a different feature rather than a test.

        If an attestation layer is ever added, the hook points are marked in
        {PrimaryVenueAdapter}: the freshness check belongs in `quote` (returning
        0, alongside the availableShares check above) and its enforcement inside
        the token's `mint`.
    //////////////////////////////////////////////////////////////*/

    function test_QuoteReturnsZeroWhenVaultReserveInsufficient() public {
        _fundVault(1_000e18);

        uint256 amountIn = 500e18;
        assertGt(primary.quote(address(equity), address(stable), amountIn), 0, "funded vault should quote a sell");

        // Drain below the requirement.
        vm.prank(admin);
        vault.adminWithdraw(stranger, 1_000e18 - 1);

        assertEq(primary.quote(address(equity), address(stable), amountIn), 0, "drained vault should quote 0");
    }

    function test_QuoteReturnsZeroForUnsupportedPair() public view {
        assertEq(primary.quote(address(other), address(stable), 1e18), 0, "other/stable should quote 0");
        assertEq(primary.quote(address(stable), address(other), 1e18), 0, "stable/other should quote 0");
        assertEq(primary.quote(address(other), address(other), 1e18), 0, "other/other should quote 0");
        assertEq(primary.quote(address(stable), address(stable), 1e18), 0, "stable/stable should quote 0");
        assertEq(primary.quote(address(equity), address(equity), 1e18), 0, "equity/equity should quote 0");
    }

    /// @dev A quantity too small to resolve to one share is unfillable, not a
    ///      revert — the same graceful-degradation rule as every other
    ///      precondition.
    function test_QuoteReturnsZeroWhenAmountRoundsToZeroShares() public {
        _rebase(1_000e18);
        _fundVault(1e24);

        assertEq(primary.quote(address(stable), address(equity), 1), 0, "dust buy should quote 0");
        assertEq(primary.quote(address(equity), address(stable), 1), 0, "dust sell should quote 0");
        assertEq(primary.quote(address(stable), address(equity), 0), 0, "zero buy should quote 0");
    }

    /// @notice The buy quote reports what `mint` will ACTUALLY produce, not the
    ///         nominal `amountIn`.
    /// @dev WHY THIS IS NOT ROUNDING PEDANTRY. This figure is what Router's
    ///      best-execution loop compares against every other venue. Returning
    ///      `amountIn` verbatim would overstate primary's output and could win
    ///      the comparison against an AMM quote that would genuinely have
    ///      delivered more — a rounding-driven misroute leaving the client
    ///      materially worse off.
    function test_BuyQuoteReflectsActualMintableOutput_NotNominalAmountIn() public {
        // 100 * 1e18 does not divide evenly by 3e18: floor gives 33 shares,
        // worth 99, one wei short of the 100 requested.
        _rebase(3e18);

        uint256 amountIn = 100;

        uint256 quoted = primary.quote(address(stable), address(equity), amountIn);

        assertLt(quoted, amountIn, "quote must not overstate output as nominal amountIn");
        assertEq(quoted, equity.sharesToAmount(equity.amountToShares(amountIn)), "quote != actual mintable value");
        assertEq(quoted, 99, "arithmetic drifted from the worked example");
    }

    /// @dev And the sell quote agrees with the payout {swap} will compute from
    ///      the same share quantity — by using the same expression, not by two
    ///      derivations that happen to coincide.
    function test_SellQuoteEqualsFlooredParValueOfResolvedShares() public {
        _rebase(1.333e18);
        _fundVault(1e30);

        uint256 amountIn = 12_345_678_901_234_567;
        uint256 quoted = primary.quote(address(equity), address(stable), amountIn);

        assertEq(quoted, equity.sharesToAmount(equity.amountToShares(amountIn)), "sell quote != floored par value");
        assertLe(quoted, amountIn, "sell quote exceeded the requested amount");
    }

    /*//////////////////////////////////////////////////////////////
                RESERVE SOLVENCY AFTER AN UPWARD REBASE
    //////////////////////////////////////////////////////////////*/

    /// @notice A mint deposits stable ONCE at the multiplier of that moment. A
    ///         later upward corporate action raises what those shares are worth
    ///         without the vault receiving anything, so par redemption can come
    ///         to exceed the reserve.
    /// @dev THIS IS A CORRECTLY-HANDLED OPERATIONAL CONDITION, NOT A BUG — it
    ///      arises with every conversion in the adapter computed correctly. The
    ///      two required behaviours are asserted together here: `quote` reports
    ///      unfillable (0), and `swap` reverts rather than silently underpaying.
    function test_QuoteReturnsZeroWhenCorporateActionMakesRedemptionExceedReserve() public {
        // ---- a mint at m = 1e18 deposits exactly 1_000e18 stable ------------
        uint256 stableIn = 1_000e18;
        stable.mint(address(primary), stableIn);
        primary.swap(_buyOrder(stableIn), whale);

        uint256 mintedShares = equity.amountToShares(stableIn);
        assertEq(vault.reserveBalance(), stableIn, "vault should hold exactly the deposit");

        // ---- the multiplier doubles; the vault receives nothing -------------
        _rebase(2e18);

        uint256 required = equity.sharesToAmount(mintedShares);
        assertGt(required, vault.reserveBalance(), "test did not create the shortfall it intends to check");

        // BEHAVIOUR 1 — quote reports unfillable rather than reverting.
        uint256 clientAmountIn = equity.sharesToAmount(mintedShares);
        assertEq(
            primary.quote(address(equity), address(stable), clientAmountIn), 0, "quote should be 0 under shortfall"
        );

        // BEHAVIOUR 2 — a swap attempted anyway reverts, never underpays.
        OrderTypes.Order memory order = _fundAdapterForSell(mintedShares);

        vm.expectRevert(PrimaryVenueAdapter.InsufficientReserve.selector);
        primary.swap(order, recipient);
    }

    /// @dev And the condition is curable ONLY by an operator deposit. The vault
    ///      does not restore itself, and the adapter does not automate it.
    function test_ShortfallIsCuredOnlyByOperatorDeposit() public {
        uint256 stableIn = 1_000e18;
        stable.mint(address(primary), stableIn);
        primary.swap(_buyOrder(stableIn), whale);

        uint256 mintedShares = equity.amountToShares(stableIn);
        _rebase(2e18);

        // Time alone changes nothing: no keeper, no accrual, no self-healing.
        vm.warp(block.timestamp + 365 days);
        assertEq(primary.quote(address(equity), address(stable), 2_000e18), 0, "vault healed itself");

        // Recapitalization is an off-chain-triggered operator action.
        _fundVault(equity.sharesToAmount(mintedShares) - stableIn);

        assertGt(primary.quote(address(equity), address(stable), 2_000e18), 0, "quote still 0 after recapitalization");

        OrderTypes.Order memory order = _fundAdapterForSell(mintedShares);
        primary.swap(order, recipient);

        assertEq(stable.balanceOf(recipient), equity.sharesToAmount(mintedShares), "post-recapitalization payout wrong");
    }

    /*//////////////////////////////////////////////////////////////
                          DONATION RESISTANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev The adapter consumes the FUNDED amount, never its own balance. A
    ///      sweeping adapter would eat the donation, fail the engine's STEP 5
    ///      check, and be permanently bricked by one wei from anyone.
    function test_AdapterWithPreExistingStableDonation_BuySucceeds() public {
        uint256 donation = 777e18;
        uint256 amountIn = 1_000e18;

        stable.mint(donor, donation);
        vm.prank(donor);
        stable.transfer(address(primary), donation);

        stable.mint(address(primary), amountIn);

        uint256 vaultBefore = vault.reserveBalance();

        primary.swap(_buyOrder(amountIn), recipient);

        assertEq(equity.shares(recipient), equity.amountToShares(amountIn), "shares minted off the wrong amount");
        assertEq(vault.reserveBalance() - vaultBefore, amountIn, "forwarded more or less than the funded amount");
        assertEq(stable.balanceOf(address(primary)), donation, "donation was consumed or moved");
    }

    /// @notice A donated SHARE balance is not laundered into a redemption.
    /// @dev The failure this guards against is reading
    ///      `equity.shares(address(this))` as "what this settlement funded".
    ///      That total includes the donation, and settlement-local funds cannot
    ///      be told apart from donated ones by inspecting a balance — so such an
    ///      adapter would burn the donation and pay the current client for
    ///      shares someone else sent.
    function test_SellWithPriorDonation_DoesNotLaunderDonationIntoRedemption() public {
        _rebase(1.333e18);
        _fundVault(1e30);

        uint256 donation = 555_555_555_555;

        // Donated BEFORE the settlement, so it is indistinguishable from
        // settlement funds by balance alone.
        vm.prank(whale);
        equity.transferShares(address(primary), donation);

        uint256 sharesIn = 9_999_999_999_999;
        OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);

        uint256 expectedPayout = equity.sharesToAmount(sharesIn);
        uint256 vaultBefore = vault.reserveBalance();
        uint256 allocatedBefore = shareRegistry.allocatedShares(address(equity));

        vm.recordLogs();
        primary.swap(order, recipient);

        // redeem() was called with exactly sharesIn, NOT sharesIn + donation.
        assertEq(_lastRedeemShares(), sharesIn, "redeemed the donation along with the funded shares");
        assertEq(
            allocatedBefore - shareRegistry.allocatedShares(address(equity)),
            sharesIn,
            "registry backing released for more than the funded shares"
        );

        // The donation is still there, untouched — NOT zero.
        assertEq(equity.shares(address(primary)), donation, "adapter share balance should equal the donation exactly");

        // Redemption is an OUTFLOW from the vault, sized by the funded shares.
        assertEq(vaultBefore - vault.reserveBalance(), expectedPayout, "vault outflow != floored par of funded shares");
        assertEq(stable.balanceOf(recipient), expectedPayout, "recipient paid for the donation too");
    }

    /*//////////////////////////////////////////////////////////////
                      ROUNDING-DIRECTION PROOFS
    //////////////////////////////////////////////////////////////*/

    /// @notice The redemption payout floors. THIS IS THE TEST THAT ACTUALLY
    ///         DISTINGUISHES THE TWO ROUNDING CHOICES.
    /// @dev Picked so floor and ceil differ: at m = 1.5e18, 3 shares are worth
    ///      4.5, so floor gives 4 and ceil gives 5. Asserting payout == 4 AND
    ///      payout < 5 fails if the implementation ever reaches for
    ///      `sharesToAmountCeil`.
    ///
    ///      Ceiling here would be the one place in the system where rounding
    ///      favours the recipient over the protocol — backwards relative to
    ///      every other rounding decision, and a leak anyone could repeat.
    function test_RedemptionPayoutUsesFloorNotCeil() public {
        _rebase(1.5e18);
        _fundVault(1e24);

        uint256 sharesIn = 3;

        uint256 flooredPar = equity.sharesToAmount(sharesIn);
        uint256 ceiledPar = equity.sharesToAmountCeil(sharesIn);
        assertEq(flooredPar, 4, "worked example drifted");
        assertEq(ceiledPar, 5, "worked example drifted");
        assertGt(ceiledPar, flooredPar, "test cannot distinguish the two roundings");

        OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);
        uint256 recipientBefore = stable.balanceOf(recipient);

        uint256 payout = primary.swap(order, recipient);

        assertEq(payout, flooredPar, "payout != floored par value");
        assertLt(payout, ceiledPar, "payout used the CEIL helper -- rounding favours the recipient");
        assertEq(stable.balanceOf(recipient) - recipientBefore, flooredPar, "delivered amount != floored par");
    }

    /// @dev Same proof across a table, so it is not one lucky pair of numbers.
    function test_RedemptionPayoutUsesFloorNotCeil_acrossMultipliers() public {
        _fundVault(1e30);

        uint256[4] memory multipliers = [uint256(1.5e18), 2.25e18, 3.7e18, 1e21 + 1];

        for (uint256 i; i < multipliers.length; ++i) {
            _rebase(multipliers[i]);

            uint256 sharesIn = 7;
            uint256 flooredPar = equity.sharesToAmount(sharesIn);
            uint256 ceiledPar = equity.sharesToAmountCeil(sharesIn);

            // Only meaningful where the two actually differ.
            if (ceiledPar == flooredPar) continue;

            OrderTypes.Order memory order = _fundAdapterForSell(sharesIn);
            uint256 payout = primary.swap(order, recipient);

            assertEq(payout, flooredPar, "payout != floored par value");
            assertLt(payout, ceiledPar, "payout used the CEIL helper");
        }
    }

    /// @notice A buy immediately followed by redeeming exactly those shares back
    ///         never returns more stable than was deposited.
    /// @dev SCOPE OF THIS PROOF, STATED PRECISELY BECAUSE IT IS EASY TO
    ///      OVERCLAIM: this proves NON-INFLATION, and it holds for EITHER
    ///      rounding choice on the payout. With S = floor(A * 1e18 / m),
    ///      ceil(S * m / 1e18) <= A holds too, because A is already an integer.
    ///
    ///      SO THIS TEST IS NOT EVIDENCE FOR CHOOSING FLOOR OVER CEIL, AND IT
    ///      WOULD NOT HAVE CAUGHT A CEIL-BASED IMPLEMENTATION. That choice is
    ///      pinned separately by {test_RedemptionPayoutUsesFloorNotCeil}.
    ///
    ///      The equality predicate is computed with `mulmod`, which evaluates
    ///      `(stableIn * 1e18) % m` at full width — independently of the
    ///      contract, and without the overflow a plain multiplication would hit.
    function test_MintThenImmediateRedeem_NeverReturnsMoreStableThanDeposited() public {
        // Up-only, so the multipliers ascend. The middle entries are chosen so
        // stableIn * 1e18 does NOT divide evenly by m.
        uint256[4] memory multipliers = [WAD, 3e18, 7e18, 1.333e24];
        uint256[4] memory deposits = [uint256(1_000e18), 100, 999e18, 1e24 + 7];

        for (uint256 i; i < multipliers.length; ++i) {
            if (multipliers[i] > equity.multiplier()) _rebase(multipliers[i]);

            uint256 m = equity.multiplier();
            uint256 stableIn = deposits[i];

            // ---- buy ----
            stable.mint(address(primary), stableIn);
            uint256 mintedShares = equity.amountToShares(stableIn);
            if (mintedShares == 0) {
                // Unfillable at this multiplier; the adapter rejects it and there
                // is no round trip to measure.
                vm.expectRevert(PrimaryVenueAdapter.ZeroAmount.selector);
                primary.swap(_buyOrder(stableIn), whale);
                continue;
            }
            primary.swap(_buyOrder(stableIn), whale);

            // ---- sell exactly those shares back, at the SAME multiplier ----
            OrderTypes.Order memory order = _fundAdapterForSell(mintedShares);
            uint256 recipientBefore = stable.balanceOf(recipient);
            primary.swap(order, recipient);
            uint256 returned = stable.balanceOf(recipient) - recipientBefore;

            assertLe(returned, stableIn, "round trip returned MORE stable than was deposited");

            if (mulmod(stableIn, WAD, m) == 0) {
                assertEq(returned, stableIn, "exact division should round trip exactly");
            } else {
                assertLt(returned, stableIn, "inexact division should lose to flooring");
            }
        }
    }

    /// @dev Named `testFuzz_` rather than `fuzz_`: Foundry collects only
    ///      `test`-prefixed functions, so a `fuzz_`-prefixed one would compile,
    ///      appear to exist, and silently never run.
    ///
    ///      NON-INFLATION ONLY — see the scope note on the table-driven test
    ///      above. This would pass against a ceil-based payout too.
    function testFuzz_MintThenRedeemNeverInflatesValue(uint256 stableIn, uint256 m) public {
        m = bound(m, WAD, 1e24);
        stableIn = bound(stableIn, 1, 1e30);

        if (m > WAD) _rebase(m);

        uint256 mintedShares = equity.amountToShares(stableIn);
        vm.assume(mintedShares > 0);

        stable.mint(address(primary), stableIn);
        primary.swap(_buyOrder(stableIn), whale);

        OrderTypes.Order memory order = _fundAdapterForSell(mintedShares);
        uint256 recipientBefore = stable.balanceOf(recipient);
        primary.swap(order, recipient);

        assertLe(stable.balanceOf(recipient) - recipientBefore, stableIn, "round trip inflated value");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        FULL-STACK TESTS

    These are the only tests permitted to start from a client-facing original
    amountIn, because here the SettlementEngine performs the floor resolution
    itself rather than the test standing in for it.
//////////////////////////////////////////////////////////////////////////*/

contract PrimaryVenueAdapterFullStackTest is PrimaryAdapterFixture {
    function setUp() public {
        _deployAndWire();
    }

    /// @dev Refresh the Safe's share allowance to the engine immediately before a
    ///      sell. Required, not decorative: `approveShares` stores a TOKEN
    ///      allowance, so the share permission it represents DECAYS as the
    ///      multiplier rises. A grant made before a rebase permits strictly
    ///      fewer shares afterwards, and the sell would revert
    ///      `InsufficientAllowance` for a liveness reason unrelated to anything
    ///      Part B is testing.
    function _refreshShareAllowance(uint256 shareAmount) internal {
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), shareAmount);
    }

    function _submitAsOperator(OrderTypes.Order memory o) internal returns (uint256) {
        vm.prank(operator);
        return module.submitOrder(o);
    }

    /*//////////////////////////////////////////////////////////////
                  QUOTE / SETTLEMENT CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice What {quote} predicts at the venue boundary is what a real
    ///         settlement resolves to, at an awkward multiplier.
    /// @dev PROVES TWO SEPARATE CLAIMS, AND THEY MUST NOT BE CONFLATED:
    ///
    ///      (a) THE PART B PROPERTY — the adapter and `quote` agree on GROSS
    ///          output at the venue/engine boundary. This is what
    ///          primary-vs-secondary routing depends on: a quote Router compares
    ///          against other venues has to be what the venue actually delivers.
    ///
    ///      (b) AN A4 PROPERTY RESTATED — the engine's existing fee applies on
    ///          top of that gross figure. A fee genuinely applies between gross
    ///          venue output and client receipt, so the client's receipt is
    ///          asserted against gross-minus-fee and NEVER against `quote`
    ///          directly.
    ///
    ///      The fee constants are READ FROM THE ENGINE rather than hardcoded, so
    ///      a future fee-parameter change cannot silently desynchronize this test
    ///      from the contract it tests.
    function test_SellQuoteMatchesActualSettlementSharesAtNonUnityMultiplier() public {
        uint256 m = 1.333e18;
        _rebase(m);
        _fundVault(1e30);

        // 12_345_678_901_234_567 * 1e18 does not divide evenly by 1.333e18.
        uint256 clientAmountIn = 12_345_678_901_234_567;
        assertTrue(mulmod(clientAmountIn, WAD, m) != 0, "test needs an inexact division to be meaningful");

        // ---- STEP 1: quote with the CLIENT'S ORIGINAL, UNRESOLVED amount ----
        uint256 required = primary.quote(address(equity), address(stable), clientAmountIn);
        uint256 sharesInQuoted = equity.amountToShares(clientAmountIn);
        assertGt(required, 0, "primary should be able to fill this sell");

        // ---- STEP 2: settle the SAME original amount through the full stack --
        _refreshShareAllowance(sharesInQuoted * 2);

        uint256 safeStableBefore = stable.balanceOf(safe);
        uint256 allocatedBefore = shareRegistry.allocatedShares(address(equity));

        _submitAsOperator(_sellOrder(clientAmountIn));

        // The registry release equals the shares the adapter actually redeemed,
        // which is the engine-resolved quantity the ceiling inverse recovered.
        uint256 sharesReceived = allocatedBefore - shareRegistry.allocatedShares(address(equity));

        // ---- ASSERT (a): gross-to-gross at the venue boundary, PRE-FEE ------
        assertEq(sharesReceived, sharesInQuoted, "settlement resolved a different share quantity than quote predicted");

        uint256 grossOutput = equity.sharesToAmount(sharesReceived);
        assertEq(grossOutput, required, "gross venue output != quoted figure");

        // ---- ASSERT (b): the engine's existing fee, on top ------------------
        uint256 expectedFee = (grossOutput * engine.FEE_BPS()) / engine.BPS_DENOMINATOR();
        uint256 expectedNet = grossOutput - expectedFee;

        assertEq(stable.balanceOf(safe) - safeStableBefore, expectedNet, "client receipt != gross minus engine fee");
        assertEq(stable.balanceOf(feeTo), expectedFee, "fee recipient received the wrong amount");

        // And the net is NOT the quote — stated as an assertion so nobody
        // "fixes" claim (a) by asserting the wrong thing.
        assertLt(expectedNet, required, "a fee should apply between gross output and client receipt");
    }

    /// @dev Named `testFuzz_` for the reason given on the direct-suite fuzz test.
    function testFuzz_QuoteAndSettlementAgreeAcrossMultipliers(uint256 clientAmountIn, uint256 m) public {
        m = bound(m, WAD, 1e24);
        clientAmountIn = bound(clientAmountIn, 1, 1e26);

        if (m > WAD) _rebase(m);
        _fundVault(1e36);

        uint256 sharesInQuoted = equity.amountToShares(clientAmountIn);
        vm.assume(sharesInQuoted > 0);
        vm.assume(sharesInQuoted <= equity.shares(safe));

        uint256 required = primary.quote(address(equity), address(stable), clientAmountIn);
        vm.assume(required > 0);

        // The engine rejects a settlement that delivers nothing, and a gross
        // output small enough to round the fee to zero is legal but makes the
        // fee assertion vacuous rather than wrong.
        _refreshShareAllowance(sharesInQuoted);

        uint256 safeStableBefore = stable.balanceOf(safe);
        uint256 feeToBefore = stable.balanceOf(feeTo);
        uint256 allocatedBefore = shareRegistry.allocatedShares(address(equity));

        _submitAsOperator(_sellOrder(clientAmountIn));

        uint256 sharesReceived = allocatedBefore - shareRegistry.allocatedShares(address(equity));

        // (a) the Part B property: quote and settlement agree on GROSS.
        assertEq(sharesReceived, sharesInQuoted, "settlement share quantity != quoted share quantity");

        uint256 grossOutput = equity.sharesToAmount(sharesReceived);
        assertEq(grossOutput, required, "gross venue output != quoted figure");

        // (b) net receipt is gross minus the engine's fee — asserted separately,
        // never as equal to the quote.
        uint256 expectedFee = (grossOutput * engine.FEE_BPS()) / engine.BPS_DENOMINATOR();
        assertEq(stable.balanceOf(safe) - safeStableBefore, grossOutput - expectedFee, "net receipt != gross - fee");
        assertEq(stable.balanceOf(feeTo) - feeToBefore, expectedFee, "fee != gross * FEE_BPS / BPS_DENOMINATOR");
    }

    /*//////////////////////////////////////////////////////////////
              THE CENTRAL ARCHITECTURE CLAIM, EXERCISED
    //////////////////////////////////////////////////////////////*/

    /// @notice A full buy settles through the primary venue end to end, with the
    ///         engine's retention checks unmodified.
    /// @dev The point is what ISN'T here: no special case anywhere in Router or
    ///      SettlementEngine for this venue. If STEP 5 or STEP 10 needed an
    ///      exemption for a primary market, this test would revert.
    function test_FullStackBuySettlesThroughPrimaryVenue() public {
        uint256 amountIn = 1_000e18;
        uint256 safeSharesBefore = equity.shares(safe);

        uint256 amountOut = _submitAsOperator(_buyOrder(amountIn));

        assertGt(amountOut, 0, "buy delivered nothing");
        assertGt(equity.shares(safe), safeSharesBefore, "client received no shares");
        assertEq(vault.reserveBalance(), amountIn, "vault did not receive exactly the funded stable");
        assertEq(stable.balanceOf(address(primary)), 0, "adapter retained stable -- STEP 5 would have caught this");
        assertEq(equity.shares(address(primary)), 0, "adapter retained shares");
    }

    /// @notice A full sell settles through the primary venue, and the adapter's
    ///         share balance returns to EXACTLY its pre-settlement level.
    /// @dev The engine tolerates one wei-share of drift on the sell leg. This
    ///      adapter uses NONE of it: it burns an exact share count rather than
    ///      spending in token terms, so the drift is structurally zero. Asserted
    ///      as exact equality, not as `<= 1`.
    function test_FullStackSellUsesNoneOfEngineDriftTolerance() public {
        _rebase(1.333e18);
        _fundVault(1e30);

        uint256 clientAmountIn = 500e18;
        _refreshShareAllowance(equity.amountToShares(clientAmountIn) * 2);

        uint256 adapterSharesBefore = equity.shares(address(primary));

        _submitAsOperator(_sellOrder(clientAmountIn));

        assertEq(equity.shares(address(primary)), adapterSharesBefore, "adapter share balance drifted");
    }

    /// @notice Best execution picks the primary venue when it quotes higher, with
    ///         no logic anywhere that knows what a primary market is.
    /// @dev This is the Part B claim in one assertion: the choice between minting
    ///      at par and buying on the AMM is Router's pre-existing
    ///      `candidate > best` comparison, unmodified.
    function test_BestExecution_SelectsPrimaryWhenItQuotesHigher() public {
        // AMM deliberately priced below par.
        amm.setOutputRate(0.5e18);

        OrderTypes.Order memory o = _buyOrder(1_000e18);
        o.venueId = bytes32(0); // best execution

        vm.recordLogs();
        _submitAsOperator(o);

        assertEq(_resolvedVenueId(), PRIMARY_VENUE, "best execution did not select the primary venue");
    }

    function test_BestExecution_SelectsAMMWhenItQuotesHigher() public {
        // AMM priced above par: 1 stable buys 2 tokens' worth.
        amm.setOutputRate(2e18);

        OrderTypes.Order memory o = _buyOrder(1_000e18);
        o.venueId = bytes32(0);

        vm.recordLogs();
        _submitAsOperator(o);

        assertEq(_resolvedVenueId(), AMM_VENUE, "best execution did not select the AMM");
    }

    /// @notice When an upward corporate action exhausts the primary reserve, a
    ///         sell transparently falls back to the AMM.
    /// @dev NO SPECIAL-CASING ANYWHERE. The primary quote returns 0, Router's
    ///      existing strictly-greater comparison skips it because `best` starts
    ///      at zero, and the AMM wins by default. Router and SettlementEngine are
    ///      untouched by Part B.
    function test_BestExecution_FallsBackToAMMWhenPrimaryReserveExhaustedByRebase() public {
        // A mint deposits stable once, at m = 1e18.
        uint256 stableIn = 1_000e18;
        stable.mint(address(primary), stableIn);
        primary.swap(_buyOrder(stableIn), whale);

        // The multiplier doubles; the vault receives nothing.
        _rebase(2e18);

        uint256 clientAmountIn = 2_000e18;
        assertEq(
            primary.quote(address(equity), address(stable), clientAmountIn),
            0,
            "test needs the primary to be unfillable"
        );

        amm.setOutputRate(1e18);
        _refreshShareAllowance(equity.amountToShares(clientAmountIn) * 2);

        OrderTypes.Order memory o = _sellOrder(clientAmountIn);
        o.venueId = bytes32(0); // best execution

        vm.recordLogs();
        uint256 amountOut = _submitAsOperator(o);

        assertEq(_resolvedVenueId(), AMM_VENUE, "did not fall back to the AMM");
        assertGt(amountOut, 0, "fallback settlement delivered nothing");
    }

    /// @dev Reads `resolvedVenueId` out of Router's {OrderRouted}. Indexed, so it
    ///      is topic 2.
    function _resolvedVenueId() private returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = Router.OrderRouted.selector;

        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == address(router) && log.topics.length > 2 && log.topics[0] == topic) {
                return log.topics[2];
            }
        }
        fail();
        return bytes32(0);
    }
}
