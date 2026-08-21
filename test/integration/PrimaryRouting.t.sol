// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TradingModule} from "../../src/accounts/TradingModule.sol";
import {Router} from "../../src/core/Router.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {PrimaryVenueAdapter} from "../../src/primary/PrimaryVenueAdapter.sol";

import {PrimaryAdapterFixture} from "../PrimaryVenueAdapter.t.sol";

/// @title PrimaryRoutingTest
/// @notice PART B END-TO-END PROOF: primary vs secondary routing through the
///         real Safe -> TradingModule -> Router -> SettlementEngine -> adapter
///         stack, with both venues registered.
/// @dev ============ WHAT THIS SUITE IS ACTUALLY PROVING ============
///      Not that a comparison works — that Router's comparison, written in A2
///      and untouched since, ALREADY DOES THIS. Part B's claim is a negative
///      one, and a negative claim is only provable by exercising the positive
///      path with nothing added:
///
///        Router.sol       — ZERO changes
///        SettlementEngine.sol — ZERO changes
///        VenueRegistry.sol    — ZERO changes
///
///      So every test here submits through the unmodified stack, and the
///      regression tests below re-run A4's OWN custody post-condition —
///      copied verbatim, not paraphrased — with settlements routed through
///      the primary venue instead of the AMM mock. If a primary market needed
///      an exemption anywhere in the engine, those are the tests that would
///      fail.
///      ==============================================================
///
///      ============ TWO WIRING STEPS THAT DIFFER FROM THE BRIEF ============
///      The Part B wiring instructions named two mechanisms this system does
///      not have, so the fixture uses what exists:
///
///        - "register via the existing two-step propose/commit flow" —
///          {VenueRegistry} has NO propose/commit flow. `setAdapter` is a
///          single admin call, and its NatSpec states that register and replace
///          are deliberately one function. The fixture uses `setAdapter`.
///        - "registry attests sufficient available shares with a fresh
///          attestation" — {MockShareRegistry} has no attestation layer at all;
///          custody attestation is the other Part B option. The real and only
///          precondition is `availableShares >= sharesNeeded`, which the
///          fixture establishes via `setCustodiedShares` and which
///          {testFuzz_PrimaryNeverSelectedWhenSharesInsufficient} exercises
///          from the failing side.
///      ====================================================================
contract PrimaryRoutingTest is PrimaryAdapterFixture {
    /// @dev A4's custody snapshot, structurally identical to the one in
    ///      test/SettlementEngine.t.sol. Reproduced rather than imported so the
    ///      assertions this suite claims to re-run are visibly the same ones.
    struct Custody {
        uint256 engineIn;
        uint256 engineOut;
        uint256 engineShares;
        uint256 adapterIn;
        uint256 adapterInShares;
    }

    function setUp() public {
        _deployAndWire();

        // Step 5 of the deployment wiring: the admin seeds the vault with an
        // initial stable reserve. Without this, primary can mint but cannot
        // redeem, and every sell quote would return 0 for a liveness reason
        // rather than an economic one.
        _fundVault(1e30);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Refresh the Safe's share allowance to the engine immediately before
    ///      a sell. REQUIRED, not decorative: `approveShares` stores a TOKEN
    ///      allowance, so the share permission it represents decays as the
    ///      multiplier rises. A grant made before a rebase permits strictly
    ///      fewer shares afterwards, and the sell would revert
    ///      `InsufficientAllowance` for a liveness reason unrelated to routing.
    function _refreshShareAllowance(uint256 shareAmount) internal {
        vm.prank(operator);
        module.setEngineShareAllowance(address(engine), address(equity), shareAmount);
    }

    function _submitAsOperator(OrderTypes.Order memory o) internal returns (uint256) {
        vm.prank(operator);
        return module.submitOrder(o);
    }

    /// @dev Submit for best execution: `venueId == bytes32(0)` is what opts an
    ///      order into Router's comparison loop.
    function _submitForBestExecution(OrderTypes.Order memory o) internal returns (uint256) {
        o.venueId = bytes32(0);
        vm.recordLogs();
        return _submitAsOperator(o);
    }

    /// @dev Reads Router's {OrderRouted}. `resolvedVenueId` is indexed, so it is
    ///      topic 2; `indicativeQuote` and `amountOut` are unindexed data.
    function _routed() internal returns (bytes32 venueId, uint256 indicativeQuote, uint256 amountOut) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = Router.OrderRouted.selector;

        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == address(router) && log.topics.length > 2 && log.topics[0] == topic) {
                (indicativeQuote, amountOut) = abi.decode(log.data, (uint256, uint256));
                return (log.topics[2], indicativeQuote, amountOut);
            }
        }
        fail();
    }

    function _resolvedVenueId() internal returns (bytes32 venueId) {
        (venueId,,) = _routed();
    }

    /// @dev Drive `availableShares` to exactly `target` by moving the CUSTODIED
    ///      figure, which is the only lever an admin has: `setCustodiedShares`
    ///      refuses to go below what is already allocated, so the floor is
    ///      whatever has been minted so far.
    function _setAvailableShares(uint256 target) internal {
        uint256 allocated = shareRegistry.allocatedShares(address(equity));

        vm.prank(admin);
        shareRegistry.setCustodiedShares(address(equity), allocated + target);
    }

    function _snapshot(address adapterUnderTest, address assetIn, address assetOut)
        internal
        view
        returns (Custody memory c)
    {
        c.engineIn = IERC20(assetIn).balanceOf(address(engine));
        c.engineOut = IERC20(assetOut).balanceOf(address(engine));
        c.engineShares = equity.shares(address(engine));
        c.adapterIn = IERC20(assetIn).balanceOf(adapterUnderTest);
        c.adapterInShares = equity.shares(adapterUnderTest);
    }

    /// @dev A4'S CUSTODY POST-CONDITION, COPIED VERBATIM from
    ///      test/SettlementEngine.t.sol and parameterized only by which adapter
    ///      is under test. Not one assertion is loosened, and the sell branch
    ///      keeps A4's one wei-share tolerance rather than being tightened to
    ///      suit this adapter — the point is that the EXISTING assertion passes,
    ///      not that a new one can be written to fit.
    function _assertCustodyUnchanged(
        Custody memory before,
        address adapterUnderTest,
        address assetIn,
        address assetOut,
        bool isSell
    ) internal view {
        assertEq(IERC20(assetIn).balanceOf(address(engine)), before.engineIn, "engine assetIn delta");
        assertEq(IERC20(assetOut).balanceOf(address(engine)), before.engineOut, "engine assetOut delta");
        assertEq(equity.shares(address(engine)), before.engineShares, "engine share delta");

        if (isSell) {
            uint256 nowShares = equity.shares(adapterUnderTest);
            uint256 drift = nowShares > before.adapterInShares
                ? nowShares - before.adapterInShares
                : before.adapterInShares - nowShares;
            assertLe(drift, 1, "adapter share drift exceeds one wei-share");
        } else {
            assertEq(IERC20(assetIn).balanceOf(adapterUnderTest), before.adapterIn, "adapter assetIn delta");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT WIRING
    //////////////////////////////////////////////////////////////*/

    /// @notice The seven wiring steps, asserted as state rather than assumed.
    /// @dev Steps 3 and 4 are the two post-deploy grants. Until both exist,
    ///      buys revert in the token's role check and sells in the vault's —
    ///      loudly, which is why they are asserted here rather than discovered
    ///      in a settlement.
    function test_DeploymentWiringIsComplete() public view {
        // 1-2: vault then adapter, no circular dependency.
        assertEq(address(primary.stable()), address(stable), "adapter/stable mismatch");
        assertEq(address(primary.vault()), address(vault), "adapter/vault mismatch");
        assertEq(address(vault.stable()), address(stable), "vault/stable mismatch");

        // 3: PRIMARY_ROLE on the token, so the adapter may mint and redeem.
        assertTrue(equity.hasRole(equity.PRIMARY_ROLE(), address(primary)), "adapter lacks PRIMARY_ROLE");

        // 4: ADAPTER_ROLE on the vault, so the adapter may pay redeemers.
        assertTrue(vault.hasRole(vault.ADAPTER_ROLE(), address(primary)), "adapter lacks vault ADAPTER_ROLE");

        // 5: an initial reserve exists.
        assertGt(vault.reserveBalance(), 0, "vault holds no reserve");

        // 6: registered, alongside the AMM. Single-step `setAdapter`; there is
        //    no propose/commit flow in this registry.
        assertEq(venues.getAdapter(PRIMARY_VENUE), address(primary), "primary not registered");
        assertEq(venues.getAdapter(AMM_VENUE), address(amm), "AMM not registered");
        assertEq(venues.venueCount(), 2, "expected exactly two venues");

        // 7: sufficient backing for the mint path.
        assertGt(shareRegistry.availableShares(address(equity)), 0, "no available shares to mint against");
    }

    /*//////////////////////////////////////////////////////////////
              THE HEADLINE TEST — PART B'S NAMED SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @notice THE SCENARIO THE SPEC NAMES EXPLICITLY. The AMM has drifted so
    ///         the equity trades at a PREMIUM — a buyer there gets fewer shares
    ///         per stable than minting at par would give — and best execution
    ///         mints instead.
    /// @dev WHAT MAKES THIS THE PART B PROOF: nothing in this test, in Router,
    ///      or in the engine asks "is this the primary venue?". The AMM quotes
    ///      500, primary quotes 1000, and Router's pre-existing
    ///      `candidate > indicativeQuote` picks the larger. The routing decision
    ///      is a comparison that already existed.
    function test_BestExecution_MintsWhenAMMHasDriftedAbovePar() public {
        // Equity at a premium on the AMM: one stable buys half a token's worth.
        amm.setOutputRate(0.5e18);

        uint256 amountIn = 1_000e18;

        uint256 ammQuote = amm.quote(address(stable), address(equity), amountIn);
        uint256 primaryQuote = primary.quote(address(stable), address(equity), amountIn);
        assertGt(primaryQuote, ammQuote, "test premise: primary must be the better venue here");

        uint256 sharesBefore = equity.shares(safe);
        uint256 vaultBefore = vault.reserveBalance();

        _submitForBestExecution(_buyOrder(amountIn));

        (bytes32 resolved, uint256 indicative,) = _routed();

        // Resolved to PRIMARY, not the AMM.
        assertEq(resolved, PRIMARY_VENUE, "best execution did not mint at par");
        assertEq(indicative, primaryQuote, "winning quote was not primary's");

        // The client got more shares than the AMM would have delivered. Compared
        // against the AMM's GROSS quote while the client's figure is NET of the
        // engine's fee, so this is the conservative direction.
        uint256 sharesGained = equity.shares(safe) - sharesBefore;
        assertGt(sharesGained, equity.amountToShares(ammQuote), "client did no better than the AMM would have");

        // And it really was a mint: the stable landed in the reserve vault.
        assertEq(vault.reserveBalance() - vaultBefore, amountIn, "stable did not reach the reserve vault");
        assertEq(amm.swapCount(), 0, "the AMM was touched");
    }

    /// @notice The mirror image: when the AMM is genuinely cheaper than par,
    ///         best execution buys there. Primary is not privileged.
    function test_BestExecution_UsesAMMWhenItOffersBetterPriceThanPar() public {
        amm.setOutputRate(2e18);

        uint256 amountIn = 1_000e18;

        assertGt(
            amm.quote(address(stable), address(equity), amountIn),
            primary.quote(address(stable), address(equity), amountIn),
            "test premise: the AMM must be the better venue here"
        );

        uint256 vaultBefore = vault.reserveBalance();

        _submitForBestExecution(_buyOrder(amountIn));

        assertEq(_resolvedVenueId(), AMM_VENUE, "best execution did not use the cheaper AMM");
        assertEq(amm.swapCount(), 1, "the AMM was not used");
        assertEq(vault.reserveBalance(), vaultBefore, "primary was touched on an AMM route");
    }

    /// @notice Symmetric on the sell side: when the AMM bids below par, best
    ///         execution redeems at par instead.
    function test_BestExecution_SymmetricOnSell_RedeemsWhenAMMBelowPar() public {
        _rebase(1.333e18);
        amm.setOutputRate(0.5e18);

        uint256 amountIn = 500e18;
        uint256 sharesIn = equity.amountToShares(amountIn);
        _refreshShareAllowance(sharesIn * 2);

        assertGt(
            primary.quote(address(equity), address(stable), amountIn),
            amm.quote(address(equity), address(stable), amountIn),
            "test premise: primary must be the better bid here"
        );

        uint256 vaultBefore = vault.reserveBalance();
        uint256 allocatedBefore = shareRegistry.allocatedShares(address(equity));

        _submitForBestExecution(_sellOrder(amountIn));

        assertEq(_resolvedVenueId(), PRIMARY_VENUE, "best execution did not redeem at par");

        // A real redemption: the vault paid out, and registry backing was
        // released for exactly the engine-resolved share quantity.
        assertGt(vaultBefore, vault.reserveBalance(), "the vault did not pay out");
        assertEq(
            allocatedBefore - shareRegistry.allocatedShares(address(equity)),
            sharesIn,
            "backing released != engine-resolved sharesIn"
        );
        assertEq(amm.swapCount(), 0, "the AMM was touched");
    }

    /// @notice Best execution is OPT-IN. An explicit `venueId` is honoured even
    ///         when the other venue would have been better.
    /// @dev Router takes NO quote for an explicit venue — the caller has already
    ///      chosen — so the emitted `indicativeQuote` is 0. Asserted, because it
    ///      is the observable difference between "compared and picked this" and
    ///      "was told to use this".
    function test_BestExecution_ExplicitVenueBypassesComparison() public {
        // The AMM is strictly worse than par here.
        amm.setOutputRate(0.5e18);

        uint256 amountIn = 1_000e18;
        assertGt(
            primary.quote(address(stable), address(equity), amountIn),
            amm.quote(address(stable), address(equity), amountIn),
            "test premise: primary must be the better venue being passed over"
        );

        uint256 vaultBefore = vault.reserveBalance();

        OrderTypes.Order memory o = _buyOrder(amountIn);
        o.venueId = AMM_VENUE; // explicit, NOT bytes32(0)

        vm.recordLogs();
        _submitAsOperator(o);

        (bytes32 resolved, uint256 indicative,) = _routed();

        assertEq(resolved, AMM_VENUE, "explicit venue choice was overridden");
        assertEq(indicative, 0, "an explicit-venue order should not be quoted");
        assertEq(amm.swapCount(), 1, "the named venue was not used");
        assertEq(vault.reserveBalance(), vaultBefore, "primary was used despite an explicit AMM choice");
    }

    /// @notice When primary cannot fill, the order falls back to the AMM without
    ///         reverting — no special-casing anywhere.
    /// @dev The mechanism is Router's pre-existing strictly-greater comparison
    ///      against an `indicativeQuote` that starts at zero: a 0 quote can
    ///      never win, so "unfillable" needs no signalling channel of its own.
    function test_BestExecution_FallsBackToAMMWhenPrimaryCannotFill() public {
        // Exhaust registry backing entirely, through the real mint path.
        _setAvailableShares(0);
        assertEq(shareRegistry.availableShares(address(equity)), 0, "backing not exhausted");

        uint256 amountIn = 1_000e18;
        assertEq(primary.quote(address(stable), address(equity), amountIn), 0, "primary should be unfillable");

        amm.setOutputRate(1e18);

        uint256 amountOut = _submitForBestExecution(_buyOrder(amountIn));

        assertEq(_resolvedVenueId(), AMM_VENUE, "did not fall back to the AMM");
        assertGt(amountOut, 0, "fallback settlement delivered nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                TIE-BREAK

        WHAT ROUTER ALREADY DOES, established by reading A2 and A3 rather than
        by deciding what it ought to do:

          - Router compares with `candidate > indicativeQuote` — STRICTLY
            greater (Router._resolveVenue). An equal quote therefore does NOT
            displace the incumbent.
          - Venues are iterated by `venueIdAt(0..venueCount-1)`, which is
            EnumerableSet order. VenueRegistry's own NatSpec warns that this
            order is NOT STABLE: removal uses swap-and-pop, so callers must not
            treat it as insertion order.

        Consequently: ON AN EXACT TIE, THE VENUE ITERATED FIRST WINS. That is
        an artifact of iteration order and a strict comparison, NOT a
        preference for either venue — and these tests assert exactly that,
        reading the expected winner from the registry's current enumeration
        rather than hardcoding "primary" or "AMM".

        NOT ASSERTED, DELIBERATELY: that primary wins ties. Introducing a
        primary-side tie preference would be new Router-adjacent behaviour this
        system does not have, and a test asserting it would be specifying a
        feature rather than pinning one.

        WORTH RECORDING ANYWAY — A TIE IN QUOTED OUTPUT IS NOT ECONOMICALLY
        NEUTRAL, even though this system does not attempt to break it
        differently. Primary settlement consumes finite registry-attested
        shares and leaves a mint/redeem audit trail against the underlying;
        AMM settlement consumes pool liquidity and leaves a public swap trace.
        The two have different consequences for backing, for disclosure, and
        for what an observer can infer. This system treats them as
        interchangeable at the quote level. A future version might not, and if
        it does, THESE ARE THE TESTS THAT SHOULD CHANGE — which is why they are
        written against the mechanism rather than against a preferred outcome.
    //////////////////////////////////////////////////////////////*/

    /// @dev Named `testFuzz_` rather than `fuzz_`: Foundry collects only
    ///      `test`-prefixed functions, so a `fuzz_`-prefixed one would compile,
    ///      appear to exist, and silently never run.
    function testFuzz_TieBetweenPrimaryAndAMM_PreservesRouterExistingBehavior(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 1e24);

        // At the deployment multiplier of 1e18 both conversions are the
        // identity, so primary's buy quote is exactly `amountIn`. A rate of 1e18
        // makes the AMM quote exactly `amountIn` too.
        amm.setOutputRate(1e18);

        uint256 primaryQuote = primary.quote(address(stable), address(equity), amountIn);
        uint256 ammQuote = amm.quote(address(stable), address(equity), amountIn);

        // The tie is VERIFIED, not assumed. Without this the test could pass
        // while silently exercising a non-tie.
        assertEq(primaryQuote, ammQuote, "test premise: the two quotes must be exactly equal");
        assertGt(primaryQuote, 0, "test premise: a tie at zero would prove nothing");

        // Whatever Router's existing iteration order already yields.
        bytes32 expectedWinner = venues.venueIdAt(0);

        _submitForBestExecution(_buyOrder(amountIn));

        assertEq(_resolvedVenueId(), expectedWinner, "tie-break diverged from Router's existing behaviour");
    }

    /// @notice The tie-break is ITERATION ORDER, not a primary preference — and
    ///         this proves it by flipping the order and watching the winner
    ///         flip with it.
    /// @dev Reversal uses only existing registry functions. With ids
    ///      [PRIMARY, AMM], removing PRIMARY swap-and-pops AMM into slot 0, and
    ///      re-adding PRIMARY appends it — so the enumeration becomes
    ///      [AMM, PRIMARY]. This also exercises the swap-and-pop behaviour
    ///      VenueRegistry documents.
    function test_TieBreakIsIterationOrderNotPrimaryPreference() public {
        amm.setOutputRate(1e18);
        uint256 amountIn = 1_000e18;

        // ---- as deployed: primary is iterated first, so primary wins -------
        assertEq(venues.venueIdAt(0), PRIMARY_VENUE, "fixture order changed");

        _submitForBestExecution(_buyOrder(amountIn));
        assertEq(_resolvedVenueId(), PRIMARY_VENUE, "incumbent did not win the tie");

        // ---- reverse the enumeration, change nothing about the quotes ------
        vm.startPrank(admin);
        venues.removeAdapter(PRIMARY_VENUE);
        venues.setAdapter(PRIMARY_VENUE, address(primary));
        vm.stopPrank();

        assertEq(venues.venueIdAt(0), AMM_VENUE, "enumeration was not reversed");

        // Same tie, same quotes, opposite winner.
        assertEq(
            primary.quote(address(stable), address(equity), amountIn),
            amm.quote(address(stable), address(equity), amountIn),
            "quotes should still be tied"
        );

        _submitForBestExecution(_buyOrder(amountIn));
        assertEq(_resolvedVenueId(), AMM_VENUE, "tie outcome did not follow iteration order");
    }

    /*//////////////////////////////////////////////////////////////
        REGRESSION — THE ACTUAL PROOF OF "DEPLOY AND REGISTER"
    //////////////////////////////////////////////////////////////*/

    /// @notice A4's custody invariants hold, unmodified, with settlements routed
    ///         through the primary venue.
    /// @dev THIS IS THE REAL PROOF OF THE MODULARITY CLAIM. The assertions are
    ///      A4's own, reproduced verbatim in {_assertCustodyUnchanged}; only the
    ///      adapter under test differs. If a primary market needed an exemption
    ///      from the engine's retention checks, this test is what would fail.
    ///
    ///      Both legs are covered, because they are enforced differently: the
    ///      buy leg by exact balance equality, the sell leg by a share-drift
    ///      bound.
    function test_AllExistingSettlementEngineInvariantsHoldWithPrimaryAdapterRegistered() public {
        _rebase(1.333e18);

        // ---- BUY through the primary venue ---------------------------------
        {
            uint256 amountIn = 1_000e18;
            Custody memory before = _snapshot(address(primary), address(stable), address(equity));
            uint256 allowanceBefore = stable.allowance(safe, address(engine));

            _submitAsOperator(_buyOrder(amountIn));

            _assertCustodyUnchanged(before, address(primary), address(stable), address(equity), false);

            // A4's allowance property: the engine debits exactly the order's
            // input amount from the client's standing approval.
            assertEq(
                allowanceBefore - stable.allowance(safe, address(engine)),
                amountIn,
                "stable allowance debit != order amountIn"
            );
        }

        // ---- SELL through the primary venue --------------------------------
        {
            uint256 amountIn = 500e18;
            uint256 sharesIn = equity.amountToShares(amountIn);
            _refreshShareAllowance(sharesIn);

            Custody memory before = _snapshot(address(primary), address(equity), address(stable));
            uint256 shareAllowanceBefore = equity.allowance(safe, address(engine));

            _submitAsOperator(_sellOrder(amountIn));

            _assertCustodyUnchanged(before, address(primary), address(equity), address(stable), true);

            // A4's share-allowance property: the debit is the CEIL of the share
            // quantity's token value, so a spender can never move more value
            // than was approved.
            assertEq(
                shareAllowanceBefore - equity.allowance(safe, address(engine)),
                equity.sharesToAmountCeil(sharesIn),
                "share allowance debit != ceil(sharesIn * m / 1e18)"
            );

            // STRONGER THAN A4 REQUIRES, and stated separately so it is not
            // mistaken for the unmodified assertion above: this adapter uses
            // NONE of the one wei-share tolerance, because it burns an exact
            // share count rather than spending in token terms.
            assertEq(equity.shares(address(primary)), before.adapterInShares, "primary adapter used drift tolerance");
        }
    }

    /// @notice Neither venue reinterprets `order.amountIn` differently from how
    ///         the engine already resolved it.
    /// @dev THE RISK THIS CLOSES. The engine rewrites `amountIn` to
    ///      `executableAmountIn` before calling an adapter (its STEP 2/STEP 4).
    ///      An adapter that re-derived the quantity from the client's original
    ///      figure — or from its own balance — would settle a different trade
    ///      than the one the engine measured. Both venues are checked against
    ///      the engine's OWN resolution, computed independently here.
    ///
    ///      The direct-adapter leg uses B.2's 5-step construction, so
    ///      `amountToSharesCeil` is only ever handed a floor's output.
    function test_SellPayoutConsistencyAcrossVenues() public {
        _rebase(1.333e18);
        amm.setOutputRate(1e18); // the AMM pays par, so payouts are comparable

        uint256 clientAmountIn = 12_345_678_901_234_567_890;

        // The engine's STEP 2 resolution, computed here rather than observed.
        uint256 engineSharesIn = equity.amountToShares(clientAmountIn);
        uint256 engineExecutableAmountIn = equity.sharesToAmount(engineSharesIn);

        // The test is only meaningful if the two figures actually differ.
        assertLt(engineExecutableAmountIn, clientAmountIn, "test premise: resolution must lose something to flooring");

        uint256 expectedFee = (engineExecutableAmountIn * engine.FEE_BPS()) / engine.BPS_DENOMINATOR();
        uint256 expectedNet = engineExecutableAmountIn - expectedFee;

        // ---- leg 1: through the PRIMARY venue ------------------------------
        _refreshShareAllowance(engineSharesIn);
        uint256 safeBefore = stable.balanceOf(safe);

        OrderTypes.Order memory o = _sellOrder(clientAmountIn);
        o.venueId = PRIMARY_VENUE;
        _submitAsOperator(o);

        uint256 netViaPrimary = stable.balanceOf(safe) - safeBefore;

        // ---- leg 2: through the AMM ----------------------------------------
        _refreshShareAllowance(engineSharesIn);
        safeBefore = stable.balanceOf(safe);

        o = _sellOrder(clientAmountIn);
        o.venueId = AMM_VENUE;
        _submitAsOperator(o);

        uint256 netViaAMM = stable.balanceOf(safe) - safeBefore;

        // The AMM saw the ENGINE-RESOLVED figure, not the client's original.
        assertEq(
            amm.lastAmountIn(), engineExecutableAmountIn, "AMM was handed a different amountIn than the engine set"
        );
        assertTrue(amm.lastAmountIn() != clientAmountIn, "AMM was handed the unresolved client figure");

        // Both venues produce the payout the engine's own resolution implies.
        assertEq(netViaPrimary, expectedNet, "primary payout inconsistent with engine resolution");
        assertEq(netViaAMM, expectedNet, "AMM payout inconsistent with engine resolution");
        assertEq(netViaPrimary, netViaAMM, "the two venues disagree on payout for an identical order");

        // ---- leg 3: the DIRECT adapter call, via B.2's 5-step construction --
        // Step 1: the target share quantity. Steps 2-4 inside the helper: fund
        // with exactly those shares, derive executableAmountIn by FLOORING, and
        // build the order from that — never the unresolved client figure.
        OrderTypes.Order memory direct = _fundAdapterForSell(engineSharesIn);
        assertEq(direct.amountIn, engineExecutableAmountIn, "5-step construction diverged from engine resolution");

        uint256 recipientBefore = stable.balanceOf(recipient);
        uint256 grossDirect = primary.swap(direct, recipient);

        // Step 5: assert against the step-1 ground truth. A direct call takes no
        // fee, so it yields the GROSS figure the engine would have split.
        assertEq(grossDirect, engineExecutableAmountIn, "direct swap gross != engine executableAmountIn");
        assertEq(stable.balanceOf(recipient) - recipientBefore, grossDirect, "direct swap delivered a different amount");
        assertEq(grossDirect - expectedFee, expectedNet, "gross minus engine fee != the net both venues paid");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Whenever registry backing is insufficient for a buy, primary
    ///         quotes 0 and Router never selects it — at ANY AMM price.
    /// @dev The AMM's rate is fuzzed alongside the shortfall precisely so the
    ///      claim is "regardless of AMM price" rather than "at the one rate the
    ///      test happened to pick".
    function testFuzz_PrimaryNeverSelectedWhenSharesInsufficient(
        uint256 sharesAvailable,
        uint256 amountIn,
        uint256 rateWad
    ) public {
        sharesAvailable = bound(sharesAvailable, 0, 1e18);
        // At m == 1e18 a buy of `amountIn` needs exactly `amountIn` shares, so
        // anything above the available figure is a genuine shortfall.
        amountIn = bound(amountIn, sharesAvailable + 1e6, 1e24);
        rateWad = bound(rateWad, 0.1e18, 3e18);

        _setAvailableShares(sharesAvailable);
        amm.setOutputRate(rateWad);

        uint256 sharesNeeded = equity.amountToShares(amountIn);
        assertGt(sharesNeeded, shareRegistry.availableShares(address(equity)), "test premise: a shortfall must exist");

        assertEq(primary.quote(address(stable), address(equity), amountIn), 0, "primary quoted a buy it cannot fill");

        _submitForBestExecution(_buyOrder(amountIn));

        assertEq(_resolvedVenueId(), AMM_VENUE, "Router selected primary despite insufficient backing");
    }

    /// @notice And the same shortfall does not break routing when primary is
    ///         explicitly named — it reverts in the token's own backing check
    ///         rather than settling something wrong.
    /// @dev `mint` is the authoritative check; {quote} only estimates. Pinned so
    ///      the estimate and the enforcement cannot drift apart unnoticed.
    function test_ExplicitPrimaryVenueRevertsWhenBackingInsufficient() public {
        _setAvailableShares(0);

        OrderTypes.Order memory o = _buyOrder(1_000e18);
        o.venueId = PRIMARY_VENUE;

        vm.prank(operator);
        vm.expectRevert();
        module.submitOrder(o);
    }
}
