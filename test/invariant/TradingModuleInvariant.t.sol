// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Safe} from "safe-contracts/Safe.sol";

import {TradingModule} from "../../src/accounts/TradingModule.sol";
import {Router} from "../../src/core/Router.sol";
import {SettlementEngine} from "../../src/core/SettlementEngine.sol";
import {IRebasingEquityToken} from "../../src/interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../../src/interfaces/IShareRegistry.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../../src/mocks/MockShareRegistry.sol";
import {VenueRegistry} from "../../src/router/VenueRegistry.sol";

import {SafeDeployer} from "../helpers/SafeDeployer.sol";
import {MockAdapter, MockStable} from "../mocks/SettlementMocks.sol";

/// @title TradingModuleHandler
/// @notice Drives {TradingModule}'s ENTIRE external surface as the operator and as
///         an attacker, with fuzzed arguments.
///
/// @dev THE OWNER DOES NOTHING HERE. Every call originates from an operator or an
///      attacker, which is what makes the invariants meaningful: they say "no
///      sequence of operator and attacker actions can reach this state", not "the
///      state happens to be fine". Owner-driven transitions — deallowlisting,
///      revocation, cap changes — are covered by the unit suite, where the
///      before/after can be asserted directly.
///
///      EVERY CALL IS LOW-LEVEL AND ABSORBS ITS REVERT. `fail_on_revert = true` is
///      set for this project, so a handler function that propagated a revert would
///      halt the run on the first rejected call — and a rejected call is the
///      NORMAL, EXPECTED outcome for most of what an attacker tries here. Absorbing
///      means the fuzzer keeps exploring past every refusal instead of stopping at
///      the first one.
///
///      THE OUTFLOW DETECTOR. Invariants 1 and 2 are worded "never decreases except
///      through a settlement", which cannot be checked from end state alone —
///      a settlement legitimately decreases one leg. So each non-settlement action
///      snapshots the Safe's holdings before and compares after, latching a flag on
///      any decrease. The invariant then asserts the flag was never set, which is
///      strictly stronger than a balance comparison at the end of the run.
contract TradingModuleHandler is Test {
    TradingModule internal immutable module;
    Router internal immutable router;
    address internal immutable safe;
    address internal immutable engine;
    MockRebasingEquityToken internal immutable equity;
    MockStable internal immutable stable;
    address internal immutable admin;
    address internal immutable operator;
    address internal immutable attacker;

    bytes32 internal immutable venue;

    /*//////////////////////////////////////////////////////////////
                             GHOST STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Latched if the Safe's stable balance ever fell outside a settlement.
    bool public unexplainedStableOutflow;

    /// @notice Latched if the Safe's share balance ever fell outside a settlement.
    bool public unexplainedShareOutflow;

    /// @notice Successful settlements, so a run that never traded is detectable.
    uint256 public settleCount;

    /// @notice Successful operator share-allowance refreshes.
    uint256 public allowanceSetCount;

    /// @notice Every address ever offered as an approval spender, plus the actors.
    ///         Invariant 3 quantifies over this.
    address[] public candidates;
    mapping(address => bool) private _isCandidate;

    /// @dev Snapshot taken by {_before}.
    uint256 private _stableBefore;
    uint256 private _sharesBefore;

    constructor(
        TradingModule module_,
        Router router_,
        address engine_,
        MockRebasingEquityToken equity_,
        MockStable stable_,
        address admin_,
        address operator_,
        address attacker_,
        bytes32 venue_
    ) {
        module = module_;
        router = router_;
        safe = module_.safe();
        engine = engine_;
        equity = equity_;
        stable = stable_;
        admin = admin_;
        operator = operator_;
        attacker = attacker_;
        venue = venue_;

        _track(operator_);
        _track(attacker_);
        _track(engine_);
        _track(address(module_));
        _track(safe);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _track(address a) private {
        // Bounded so the invariant's quantification stays cheap. 64 distinct
        // spenders is far more than any run needs to find a counterexample, and an
        // unbounded list would make every invariant check O(calls).
        if (a == address(0) || _isCandidate[a] || candidates.length >= 64) return;
        _isCandidate[a] = true;
        candidates.push(a);
    }

    function _before() private {
        _stableBefore = stable.balanceOf(safe);
        _sharesBefore = equity.shares(safe);
    }

    /// @dev Called after any action that is NOT a settlement. A decrease here is by
    ///      definition unexplained.
    function _afterNonSettlement() private {
        if (stable.balanceOf(safe) < _stableBefore) unexplainedStableOutflow = true;
        if (equity.shares(safe) < _sharesBefore) unexplainedShareOutflow = true;
    }

    function _actor(uint256 seed) private view returns (address) {
        return seed % 2 == 0 ? operator : attacker;
    }

    function _token(uint256 seed) private view returns (address) {
        return seed % 2 == 0 ? address(equity) : address(stable);
    }

    /// @dev One fuzzed call into the module, reverts absorbed.
    function _call(address caller, bytes memory data) private returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(module).call(data);
    }

    /// @dev Submit an order and classify the result for the outflow detector.
    ///
    ///      CLASSIFY BY OUTCOME, NOT BY THE ORDER'S FIELDS. An earlier version of
    ///      this handler decided "this venue is not the registered one, therefore
    ///      nothing can settle" and the invariant caught it immediately: the Router
    ///      treats `venueId == bytes32(0)` as BEST-EXECUTION AUTO-ROUTING rather than
    ///      as an unknown venue, so a zero venue settles perfectly legitimately.
    ///
    ///      Deriving the classification from whether `submitOrder` SUCCEEDED cannot
    ///      go wrong that way, and it is strictly stronger: a settlement is the one
    ///      sanctioned way the Safe's holdings may fall, and a FAILED order must
    ///      move nothing at all — which is now asserted rather than assumed.
    function _submit(address caller, OrderTypes.Order memory o) private {
        _before();

        if (_call(caller, abi.encodeCall(TradingModule.submitOrder, (o)))) {
            ++settleCount;
        } else {
            _afterNonSettlement();
        }
    }

    function candidateCount() external view returns (uint256) {
        return candidates.length;
    }

    /*//////////////////////////////////////////////////////////////
                         ACTION 1 — SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function submitBuy(uint256 actorSeed, uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1e22);

        OrderTypes.Order memory o = OrderTypes.Order({
            account: safe,
            assetIn: address(stable),
            assetOut: address(equity),
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: venue,
            deadline: block.timestamp + 1 hours
        });

        _submit(_actor(actorSeed), o);
    }

    function submitSell(uint256 actorSeed, uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1e22);

        OrderTypes.Order memory o = OrderTypes.Order({
            account: safe,
            assetIn: address(equity),
            assetOut: address(stable),
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: venue,
            deadline: block.timestamp + 1 hours
        });

        _submit(_actor(actorSeed), o);
    }

    /// @notice An order naming somebody else's account.
    function submitOrderForOther(uint256 actorSeed, address otherAccount, uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1e22);
        _track(otherAccount);

        OrderTypes.Order memory o = OrderTypes.Order({
            account: otherAccount,
            assetIn: address(stable),
            assetOut: address(equity),
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: venue,
            deadline: block.timestamp + 1 hours
        });

        _submit(_actor(actorSeed), o);
    }

    /// @notice An order routed to an arbitrary venue id, including `bytes32(0)`,
    ///         which the Router reads as best-execution rather than as unknown.
    function submitOrderToArbitraryVenue(uint256 actorSeed, bytes32 venueId, uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1e22);

        OrderTypes.Order memory o = OrderTypes.Order({
            account: safe,
            assetIn: address(equity),
            assetOut: address(stable),
            amountIn: amountIn,
            minAmountOut: 1,
            venueId: venueId,
            deadline: block.timestamp + 1 hours
        });

        _submit(_actor(actorSeed), o);
    }

    /*//////////////////////////////////////////////////////////////
                   ACTION 2 — SET ENGINE SHARE ALLOWANCE
    //////////////////////////////////////////////////////////////*/

    function setEngineShareAllowance(uint256 actorSeed, address spender, uint256 tokenSeed, uint256 shareAmount)
        external
    {
        _track(spender);
        shareAmount = bound(shareAmount, 0, 1e30);

        _before();
        if (_call(
                _actor(actorSeed),
                abi.encodeCall(TradingModule.setEngineShareAllowance, (spender, _token(tokenSeed), shareAmount))
            )) {
            ++allowanceSetCount;
        }
        _afterNonSettlement();
    }

    /// @notice The same, aimed squarely at the allowlisted engine, so the cap path
    ///         is exercised often rather than only by chance.
    function setEngineShareAllowanceOnEngine(uint256 actorSeed, uint256 shareAmount) external {
        shareAmount = bound(shareAmount, 0, 1e30);

        _before();
        if (_call(
                _actor(actorSeed),
                abi.encodeCall(TradingModule.setEngineShareAllowance, (engine, address(equity), shareAmount))
            )) {
            ++allowanceSetCount;
        }
        _afterNonSettlement();
    }

    /*//////////////////////////////////////////////////////////////
                  THE OWNER-GATED SURFACE, TRIED ANYWAY
    //////////////////////////////////////////////////////////////*/

    function trySetOperator(uint256 actorSeed, address op, bool enabled) external {
        _track(op);
        _before();
        _call(_actor(actorSeed), abi.encodeCall(TradingModule.setOperator, (op, enabled)));
        _afterNonSettlement();
    }

    function trySetApprovedEngine(uint256 actorSeed, address engine_, bool approved) external {
        _track(engine_);
        _before();
        _call(_actor(actorSeed), abi.encodeCall(TradingModule.setApprovedEngine, (engine_, approved)));
        _afterNonSettlement();
    }

    function trySetEngineShareCap(uint256 actorSeed, address engine_, uint256 tokenSeed, uint256 cap) external {
        _track(engine_);
        _before();
        _call(_actor(actorSeed), abi.encodeCall(TradingModule.setEngineShareCap, (engine_, _token(tokenSeed), cap)));
        _afterNonSettlement();
    }

    function trySetEngineTokenAllowance(uint256 actorSeed, address spender, uint256 tokenSeed, uint256 amount)
        external
    {
        _track(spender);
        _before();
        _call(
            _actor(actorSeed),
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (spender, _token(tokenSeed), amount))
        );
        _afterNonSettlement();
    }

    function tryRevokeEngineAllowance(uint256 actorSeed, address engine_, uint256 tokenSeed) external {
        _track(engine_);
        _before();
        _call(_actor(actorSeed), abi.encodeCall(TradingModule.revokeEngineAllowance, (engine_, _token(tokenSeed))));
        _afterNonSettlement();
    }

    /*//////////////////////////////////////////////////////////////
                      OFF-MODULE ATTACK ATTEMPTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Try to pull from the Safe directly, as either actor.
    /// @dev Not a module call at all, which is the point: the module could be
    ///      perfect and the account still drainable if a standing allowance existed
    ///      somewhere. This is what turns invariant 3 from a statement about module
    ///      bookkeeping into a statement about the Safe's assets.
    function tryDirectPull(uint256 actorSeed, address recipient, uint256 amount) external {
        address caller = _actor(actorSeed);
        _track(recipient);
        amount = bound(amount, 1, 1e30);

        _before();

        vm.prank(caller);
        address(stable).call(abi.encodeCall(IERC20.transferFrom, (safe, recipient, amount)));

        vm.prank(caller);
        address(equity).call(abi.encodeCall(IERC20.transferFrom, (safe, recipient, amount)));

        vm.prank(caller);
        address(equity).call(abi.encodeCall(IRebasingEquityToken.transferSharesFrom, (safe, recipient, amount)));

        _afterNonSettlement();
    }

    /// @notice Try to drive the Safe's module machinery directly.
    /// @dev Covers the shape of attack invariants 4 and 5 exist for: if any of these
    ///      landed, the owner set or module list would change and the account would
    ///      no longer be the client's.
    function tryDirectSafeCalls(uint256 actorSeed, address target, uint256 amount) external {
        address caller = _actor(actorSeed);
        _track(target);

        _before();

        vm.prank(caller);
        safe.call(abi.encodeWithSignature("enableModule(address)", target));

        vm.prank(caller);
        safe.call(abi.encodeWithSignature("disableModule(address,address)", address(0x1), address(module)));

        vm.prank(caller);
        safe.call(abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", target, 1));

        vm.prank(caller);
        safe.call(abi.encodeWithSignature("changeThreshold(uint256)", amount));

        // And the module-execution entrypoint, which only an enabled module may use.
        vm.prank(caller);
        safe.call(
            abi.encodeWithSignature(
                "execTransactionFromModule(address,uint256,bytes,uint8)",
                address(stable),
                0,
                abi.encodeCall(IERC20.transfer, (caller, 1e18)),
                uint8(0)
            )
        );

        _afterNonSettlement();
    }

    /*//////////////////////////////////////////////////////////////
                            CORPORATE ACTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Move the multiplier up, so every invariant is checked across rebases
    ///         rather than only at parity.
    /// @dev Bounded well below the point where `mulDiv` results go out of range, so
    ///      a run is not cut short by arithmetic rather than by a real finding.
    function rebase(uint256 increment) external {
        uint256 current = equity.multiplier();
        if (current >= 1e27) return;

        increment = bound(increment, 1, 1e24);

        _before();
        vm.prank(admin);
        address(equity).call(abi.encodeCall(IRebasingEquityToken.applyCorporateAction, (current + increment)));
        _afterNonSettlement();
    }
}

/// @title TradingModuleInvariantTest
/// @notice Machine-checked form of A5's two safety arguments.
///
/// @dev Invariant 3 is the load-bearing one. It says the operator can hammer every
///      function with every argument and never produce an allowance to an address
///      that is not a CURRENTLY allowlisted engine, nor push one past the owner's
///      cap. That is the approval-is-withdrawal argument stated as a property over
///      all reachable states rather than as a handful of hand-written attempts —
///      and "currently" is deliberate: it would also catch a deallowlist that
///      cleared the flag without revoking.
///
///      Invariants 4 and 5 exist because a delegatecall from a module runs in the
///      SAFE's storage context and can rewrite its owners and module list. They
///      assert no reachable path in this module gets there, complementing the
///      direct observation in `test_ModuleNeverUsesDelegateCall`.
contract TradingModuleInvariantTest is Test, SafeDeployer {
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal attacker = makeAddr("attacker");
    address internal admin = makeAddr("admin");
    address internal feeTo = makeAddr("feeTo");
    address internal sink = makeAddr("sink");

    address internal safe;
    TradingModule internal module;
    TradingModuleHandler internal handler;

    MockShareRegistry internal shareRegistry;
    MockRebasingEquityToken internal equity;
    MockStable internal stable;
    VenueRegistry internal venues;
    SettlementEngine internal engine;
    Router internal router;
    MockAdapter internal adapter;

    bytes32 internal constant VENUE = keccak256("MOCK_VENUE");
    uint256 internal constant SHARE_CAP = 1e22;
    uint256 internal constant STABLE_ALLOWANCE = 1e24;

    /*//////////////////////////////////////////////////////////////
                          EXPECTED-CONSTANT STATE
    //////////////////////////////////////////////////////////////*/

    address[] internal expectedOwners;
    uint256 internal expectedThreshold;
    address[] internal expectedModules;

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

        equity.mint(address(adapter), 1e30);
        equity.mint(safe, 1e24);
        vm.stopPrank();

        stable.mint(address(adapter), 1e32);
        stable.mint(safe, 1e26);

        module = new TradingModule(safe, address(router));
        enableModule(safe, address(module), owner);

        // The only owner actions in this suite, all before the run starts.
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
        execAsOwner(
            safe,
            address(module),
            abi.encodeCall(TradingModule.setEngineShareAllowance, (address(engine), address(equity), 1e21)),
            owner
        );
        execAsOwner(safe, address(module), abi.encodeCall(TradingModule.setOperator, (operator, true)), owner);

        // Snapshot the state the invariants assert is constant.
        expectedOwners = Safe(payable(safe)).getOwners();
        expectedThreshold = Safe(payable(safe)).getThreshold();
        expectedModules = safeModules(safe);

        handler =
            new TradingModuleHandler(module, router, address(engine), equity, stable, admin, operator, attacker, VENUE);

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                    INV 1 & 2 — NOTHING LEAVES THE SAFE
                        EXCEPT THROUGH A SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function invariant_SafeTokenBalanceOnlyFallsThroughSettlement() public view {
        assertFalse(handler.unexplainedStableOutflow(), "stable left the safe outside a settlement");
    }

    function invariant_SafeShareBalanceOnlyFallsThroughSettlement() public view {
        assertFalse(handler.unexplainedShareOutflow(), "shares left the safe outside a settlement");
    }

    /*//////////////////////////////////////////////////////////////
             INV 3 — NO ALLOWANCE TO A NON-ENGINE, EVER, AND
                       NEVER ABOVE THE OWNER'S CAP
    //////////////////////////////////////////////////////////////*/

    /// @dev THE MACHINE-CHECKED FORM OF BOTH SAFETY ARGUMENTS. Quantified over
    ///      every address the run ever offered as a spender, not just the ones a
    ///      test author thought of.
    ///
    ///      The share-cap clause applies to the REBASING token only. `stable` has no
    ///      share denomination, and its cap is legitimately zero while its token
    ///      allowance is not — the cap governs {TradingModule.setEngineShareAllowance},
    ///      which is the only operator-reachable approval path, and that path cannot
    ///      touch a non-rebasing token at all (the `approveShares` call simply does
    ///      not exist on it).
    function invariant_AllowanceOnlyToCurrentlyAllowlistedEngineWithinCap() public view {
        uint256 n = handler.candidateCount();

        for (uint256 i; i < n; ++i) {
            address spender = handler.candidates(i);

            bool allowlisted = module.isApprovedEngine(spender);

            if (!allowlisted) {
                assertEq(stable.allowance(safe, spender), 0, "stable allowance to a non-engine");
                assertEq(equity.allowance(safe, spender), 0, "equity allowance to a non-engine");
                assertEq(equity.allowanceShares(safe, spender), 0, "share allowance to a non-engine");
            } else {
                assertLe(
                    equity.allowanceShares(safe, spender),
                    module.engineShareCap(spender, address(equity)),
                    "share allowance above the owner's cap"
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
              INV 4 & 5 — THE ACCOUNT ITSELF IS UNTOUCHED
    //////////////////////////////////////////////////////////////*/

    /// @dev If a delegatecall were ever reachable from this module, this is where it
    ///      would show: a module delegatecall executes in the Safe's storage and can
    ///      append an owner or drop the threshold to one attacker key.
    function invariant_SafeOwnersAndThresholdUnchanged() public view {
        address[] memory owners = Safe(payable(safe)).getOwners();

        assertEq(owners.length, expectedOwners.length, "owner count changed");
        for (uint256 i; i < owners.length; ++i) {
            assertEq(owners[i], expectedOwners[i], "owner changed");
        }
        assertEq(Safe(payable(safe)).getThreshold(), expectedThreshold, "threshold changed");
    }

    function invariant_SafeModuleListUnchanged() public view {
        address[] memory modules = safeModules(safe);

        assertEq(modules.length, expectedModules.length, "module count changed");
        for (uint256 i; i < modules.length; ++i) {
            assertEq(modules[i], expectedModules[i], "module changed");
        }
        assertTrue(Safe(payable(safe)).isModuleEnabled(address(module)), "module disabled");
    }

    /*//////////////////////////////////////////////////////////////
           INV 6, 7 & 8 — THE MODULE'S OWN CONFIGURATION HOLDS
    //////////////////////////////////////////////////////////////*/

    /// @dev No self-escalation and no accomplices: the operator set is exactly what
    ///      the owner left it as.
    function invariant_OperatorSetUnchanged() public view {
        assertTrue(module.isOperator(operator), "operator was revoked");

        uint256 n = handler.candidateCount();
        for (uint256 i; i < n; ++i) {
            address candidate = handler.candidates(i);
            if (candidate == operator) continue;
            assertFalse(module.isOperator(candidate), "an operator was added");
        }
    }

    function invariant_ApprovedEngineSetUnchanged() public view {
        assertTrue(module.isApprovedEngine(address(engine)), "engine was deallowlisted");

        uint256 n = handler.candidateCount();
        for (uint256 i; i < n; ++i) {
            address candidate = handler.candidates(i);
            if (candidate == address(engine)) continue;
            assertFalse(module.isApprovedEngine(candidate), "an engine was allowlisted");
        }
    }

    /// @dev The bound that keeps the emergency revocation path executable. If an
    ///      operator or attacker could grow a set past it, deallowlisting could be
    ///      griefed into exceeding the block gas limit.
    function invariant_TokenSetWithinBound() public view {
        uint256 max = module.MAX_TOKENS_PER_ENGINE();

        assertLe(module.engineTokens(address(engine)).length, max, "engine set over bound");

        uint256 n = handler.candidateCount();
        for (uint256 i; i < n; ++i) {
            assertLe(module.engineTokens(handler.candidates(i)).length, max, "candidate set over bound");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            RUN COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The handler's sanctioned actions really do succeed.
    ///
    /// @dev Guards against the failure mode that would make every invariant above
    ///      VACUOUS: if the handler's calls all reverted — a misconfigured
    ///      allowance, a starved adapter, a bad venue id — the invariants would pass
    ///      while nothing was ever exercised, and the suite would be a very slow way
    ///      of asserting nothing.
    ///
    ///      A PLAIN TEST, NOT AN INVARIANT OR `afterInvariant`. Both of those are
    ///      the wrong tool and it is worth saying why, because the first two
    ///      attempts here were exactly those. As an `invariant_` function it fails
    ///      during setup, since forge evaluates invariants once before the first
    ///      call and nothing has happened yet. As `afterInvariant` it fails during
    ///      SHRINKING: forge replays candidate sequences as short as one call, and a
    ///      single `rebase` legitimately settles nothing, so the check reports a
    ///      counterexample that is an artefact of its own harness.
    ///
    ///      Driven deterministically instead. What the fuzzer reached is separately
    ///      visible in forge's per-function call distribution table.
    function test_HandlerActionsSucceed() public {
        handler.submitBuy(0, 1e20);
        assertGt(handler.settleCount(), 0, "a buy never settled");

        handler.submitSell(0, 1e20);
        assertGt(handler.settleCount(), 1, "a sell never settled");

        handler.setEngineShareAllowanceOnEngine(0, 1e20);
        assertGt(handler.allowanceSetCount(), 0, "an allowance refresh never succeeded");

        // A zero venue id is best-execution routing, not an unknown venue: the case
        // that broke the handler's first classification attempt.
        handler.submitOrderToArbitraryVenue(0, bytes32(0), 1e20);
        assertGt(handler.settleCount(), 2, "best-execution routing never settled");
    }
}
