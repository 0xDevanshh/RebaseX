// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";

/*//////////////////////////////////////////////////////////////////////////
                        SHARED TEST FIXTURE
//////////////////////////////////////////////////////////////////////////*/

/// @dev Common deployment + wiring for every suite in this file.
abstract contract ShareRegistryFixture is Test {
    MockShareRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    /// @dev Stand-ins for tokenised-equity token contracts. They only ever need
    ///      to be addresses that can be pranked, since the registry authorizes
    ///      by msg.sender and never calls back into them.
    address internal tokenA = makeAddr("tokenA");
    address internal tokenB = makeAddr("tokenB");

    /// @dev Hardcoded rather than read from the registry. Two reasons: (1) a
    ///      getter call would be an external call that consumes a pending
    ///      `vm.prank`, silently redirecting the call under test; and (2) a test
    ///      should not assert a contract against that same contract's own getter.
    bytes32 internal constant ADMIN_ROLE = 0x00;

    function _deployAndWire() internal {
        registry = new MockShareRegistry(admin);

        vm.startPrank(admin);
        registry.registerToken(tokenA);
        registry.registerToken(tokenB);
        vm.stopPrank();
    }

    function _setCustodied(address token, uint256 shares) internal {
        vm.prank(admin);
        registry.setCustodiedShares(token, shares);
    }

    function _allocate(address token, uint256 shares) internal {
        vm.prank(token);
        registry.allocateShares(shares);
    }

    function _release(address token, uint256 shares) internal {
        vm.prank(token);
        registry.releaseShares(shares);
    }

    /// @dev Asserts the three quantities that must always agree for `token`.
    function _assertRecord(address token, uint256 expectedCustodied, uint256 expectedAllocated) internal view {
        assertEq(registry.custodiedShares(token), expectedCustodied, "custodiedShares");
        assertEq(registry.allocatedShares(token), expectedAllocated, "allocatedShares");
        assertEq(registry.availableShares(token), expectedCustodied - expectedAllocated, "availableShares");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        UNIT + FUZZ TESTS
//////////////////////////////////////////////////////////////////////////*/

contract MockShareRegistryTest is ShareRegistryFixture {
    function setUp() public {
        _deployAndWire();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsAdmin() public view {
        assertTrue(registry.hasRole(ADMIN_ROLE, admin));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(IShareRegistry.ZeroAddress.selector);
        new MockShareRegistry(address(0));
    }

    function test_registerToken_marksRegistered() public {
        address tokenC = makeAddr("tokenC");
        assertFalse(registry.isRegistered(tokenC));

        vm.prank(admin);
        registry.registerToken(tokenC);

        assertTrue(registry.isRegistered(tokenC));
        _assertRecord(tokenC, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    HAPPY PATH: FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice register -> record shares -> allocate -> release -> re-allocate
    ///         the released amount, checking availableShares after every step.
    function test_lifecycle_registerRecordAllocateReleaseReallocate() public {
        // Freshly registered: nothing recorded, nothing allocated.
        _assertRecord(tokenA, 0, 0);

        // ---- record 1_000 underlying share units ---------------------------
        _setCustodied(tokenA, 1000);
        _assertRecord(tokenA, 1000, 0);

        // ---- allocate 400 --------------------------------------------------
        _allocate(tokenA, 400);
        _assertRecord(tokenA, 1000, 400);

        // ---- allocate a further 250 (cumulative 650) ------------------------
        _allocate(tokenA, 250);
        _assertRecord(tokenA, 1000, 650);

        // ---- release 150 (cumulative 500) ----------------------------------
        _release(tokenA, 150);
        _assertRecord(tokenA, 1000, 500);

        // ---- re-allocate exactly the released amount -----------------------
        // The released headroom must be reusable, not lost.
        _allocate(tokenA, 150);
        _assertRecord(tokenA, 1000, 650);

        // ---- release everything --------------------------------------------
        _release(tokenA, 650);
        _assertRecord(tokenA, 1000, 0);
    }

    function test_allocate_upToExactlyAvailable() public {
        _setCustodied(tokenA, 500);
        _allocate(tokenA, 500);
        _assertRecord(tokenA, 500, 500);
        assertEq(registry.availableShares(tokenA), 0);
    }

    function test_setCustodiedShares_canRaiseAndLowerAboveAllocated() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 600);

        _setCustodied(tokenA, 2000); // raise
        _assertRecord(tokenA, 2000, 600);

        _setCustodied(tokenA, 600); // lower to exactly allocated -- the floor
        _assertRecord(tokenA, 600, 600);
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_event_tokenRegistered() public {
        address tokenC = makeAddr("tokenC");

        vm.expectEmit(true, true, true, true, address(registry));
        emit IShareRegistry.TokenRegistered(tokenC);

        vm.prank(admin);
        registry.registerToken(tokenC);
    }

    function test_event_custodiedSharesUpdated() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 400);

        // previousCustodied = 1000, new = 1500, allocated = 400
        vm.expectEmit(true, true, true, true, address(registry));
        emit IShareRegistry.CustodiedSharesUpdated(tokenA, 1000, 1500, 400);

        vm.prank(admin);
        registry.setCustodiedShares(tokenA, 1500);
    }

    function test_event_sharesAllocated() public {
        _setCustodied(tokenA, 1000);

        // shareAmount = 400, newAllocated = 400, availableAfter = 600
        vm.expectEmit(true, true, true, true, address(registry));
        emit IShareRegistry.SharesAllocated(tokenA, 400, 400, 600);

        vm.prank(tokenA);
        registry.allocateShares(400);
    }

    function test_event_sharesReleased() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 400);

        // shareAmount = 150, newAllocated = 250, availableAfter = 750
        vm.expectEmit(true, true, true, true, address(registry));
        emit IShareRegistry.SharesReleased(tokenA, 150, 250, 750);

        vm.prank(tokenA);
        registry.releaseShares(150);
    }

    /*//////////////////////////////////////////////////////////////
                    NEGATIVE: TOKEN-FACING ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_revert_allocateFromUnregisteredAddress() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.NotRegistered.selector, stranger));
        registry.allocateShares(1);
    }

    function test_revert_releaseFromUnregisteredAddress() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.NotRegistered.selector, stranger));
        registry.releaseShares(1);
    }

    function test_revert_allocateMoreThanAvailable() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 900);

        // available is 100; asking for 101.
        vm.prank(tokenA);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.InsufficientAvailableShares.selector, 101, 100));
        registry.allocateShares(101);
    }

    /// @notice The core Part A guarantee: a token cannot mint more share units
    ///         than the registry records, not even one.
    function test_revert_allocateAgainstEmptyRecord() public {
        vm.prank(tokenA);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.InsufficientAvailableShares.selector, 1, 0));
        registry.allocateShares(1);
    }

    function test_revert_releaseMoreThanAllocated() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 300);

        vm.prank(tokenA);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.InsufficientAllocatedShares.selector, 301, 300));
        registry.releaseShares(301);
    }

    function test_revert_allocateZeroAmount() public {
        _setCustodied(tokenA, 1000);
        vm.prank(tokenA);
        vm.expectRevert(IShareRegistry.ZeroAmount.selector);
        registry.allocateShares(0);
    }

    function test_revert_releaseZeroAmount() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 100);
        vm.prank(tokenA);
        vm.expectRevert(IShareRegistry.ZeroAmount.selector);
        registry.releaseShares(0);
    }

    /*//////////////////////////////////////////////////////////////
                    NEGATIVE: THE BACKING FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_revert_setCustodiedBelowAllocated() public {
        _setCustodied(tokenA, 1000);
        _allocate(tokenA, 800);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.CustodiedBelowAllocated.selector, 799, 800));
        registry.setCustodiedShares(tokenA, 799);
    }

    function test_revert_setCustodiedOnUnregisteredToken() public {
        address tokenC = makeAddr("tokenC");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.NotRegistered.selector, tokenC));
        registry.setCustodiedShares(tokenC, 100);
    }

    /*//////////////////////////////////////////////////////////////
                        NEGATIVE: ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_revert_registerTokenFromNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        registry.registerToken(makeAddr("tokenC"));
    }

    function test_revert_setCustodiedSharesFromNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        registry.setCustodiedShares(tokenA, 100);
    }

    /// @dev A registered token has no admin power of its own; it can only move
    ///      its own allocation, never the recorded backing.
    function test_revert_tokenCannotSetItsOwnBacking() public {
        vm.prank(tokenA);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, tokenA, ADMIN_ROLE)
        );
        registry.setCustodiedShares(tokenA, 1_000_000);
    }

    function test_revert_registerZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IShareRegistry.ZeroAddress.selector);
        registry.registerToken(address(0));
    }

    function test_revert_registerTokenTwice() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.AlreadyRegistered.selector, tokenA));
        registry.registerToken(tokenA);
    }

    /*//////////////////////////////////////////////////////////////
                    SELF-KEYED ISOLATION BETWEEN TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token A's activity must never touch token B's record. This is the
    ///         property the self-keyed design buys: there is no function
    ///         argument with which A could even name B's record.
    function test_tokenA_cannotAffectTokenB() public {
        _setCustodied(tokenA, 1000);
        _setCustodied(tokenB, 500);

        _allocate(tokenA, 900);

        // B is entirely unchanged.
        _assertRecord(tokenB, 500, 0);

        // And A cannot exceed its own backing by borrowing B's headroom: total
        // recorded across both is 1500, but A is capped at its own 1000.
        vm.prank(tokenA);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.InsufficientAvailableShares.selector, 101, 100));
        registry.allocateShares(101);
    }

    /// @dev Releasing from A must not create headroom for B either.
    function test_release_isolationBetweenTokens() public {
        _setCustodied(tokenA, 1000);
        _setCustodied(tokenB, 1000);
        _allocate(tokenA, 500);
        _allocate(tokenB, 500);

        _release(tokenA, 500);

        _assertRecord(tokenA, 1000, 0);
        _assertRecord(tokenB, 1000, 500); // untouched
    }

    /// @dev A stranger cannot impersonate a token even knowing its address --
    ///      there is no address parameter to pass, so the only identity that
    ///      counts is msg.sender.
    function test_strangerCannotAllocateOnBehalfOfToken() public {
        _setCustodied(tokenA, 1000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IShareRegistry.NotRegistered.selector, stranger));
        registry.allocateShares(100);

        _assertRecord(tokenA, 1000, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice A release must always return the record to a state where the same
    ///         amount can be re-allocated -- no headroom is lost in a round trip.
    function testFuzz_releaseRestoresReallocatableHeadroom(uint256 custodied, uint256 amount) public {
        custodied = bound(custodied, 1, type(uint128).max);
        amount = bound(amount, 1, custodied);

        _setCustodied(tokenA, custodied);

        _allocate(tokenA, amount);
        _assertRecord(tokenA, custodied, amount);

        _release(tokenA, amount);
        _assertRecord(tokenA, custodied, 0);

        // The exact same amount must be allocatable again.
        _allocate(tokenA, amount);
        _assertRecord(tokenA, custodied, amount);
    }

    /// @notice Random allocate/release sequences must never break the accounting
    ///         identity or underflow. Anything that would breach the invariant
    ///         must revert rather than corrupt state.
    function testFuzz_allocateReleaseSequence(
        uint256 custodied,
        uint256[8] calldata amounts,
        bool[8] calldata isRelease
    ) public {
        custodied = bound(custodied, 1, type(uint128).max);
        _setCustodied(tokenA, custodied);

        uint256 expectedAllocated;

        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];

            if (isRelease[i]) {
                if (amount == 0 || amount > expectedAllocated) {
                    // Must revert, and must leave state untouched.
                    vm.prank(tokenA);
                    vm.expectRevert();
                    registry.releaseShares(amount);
                } else {
                    _release(tokenA, amount);
                    expectedAllocated -= amount;
                }
            } else {
                uint256 available = custodied - expectedAllocated;
                if (amount == 0 || amount > available) {
                    vm.prank(tokenA);
                    vm.expectRevert();
                    registry.allocateShares(amount);
                } else {
                    _allocate(tokenA, amount);
                    expectedAllocated += amount;
                }
            }

            // Accounting identity holds after every single step.
            _assertRecord(tokenA, custodied, expectedAllocated);
            assertLe(registry.allocatedShares(tokenA), registry.custodiedShares(tokenA));
        }
    }

    /// @notice The backing floor holds for arbitrary values: any figure at or
    ///         above allocated succeeds, anything below reverts.
    function testFuzz_backingFloor(uint256 custodied, uint256 allocated, uint256 newCustodied) public {
        custodied = bound(custodied, 1, type(uint128).max);
        allocated = bound(allocated, 1, custodied);

        _setCustodied(tokenA, custodied);
        _allocate(tokenA, allocated);

        if (newCustodied < allocated) {
            vm.prank(admin);
            vm.expectRevert(
                abi.encodeWithSelector(IShareRegistry.CustodiedBelowAllocated.selector, newCustodied, allocated)
            );
            registry.setCustodiedShares(tokenA, newCustodied);
            _assertRecord(tokenA, custodied, allocated); // unchanged
        } else {
            _setCustodied(tokenA, newCustodied);
            _assertRecord(tokenA, newCustodied, allocated);
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            INVARIANT HANDLER
//////////////////////////////////////////////////////////////////////////*/

/// @dev Exposes bounded, always-valid actions to the fuzzer and mirrors the
///      registry's accounting in ghost variables. Actions are bounded to legal
///      ranges rather than allowed to revert, so that every fuzz call does real
///      work -- an invariant suite where most calls revert proves nothing.
contract ShareRegistryHandler is Test {
    MockShareRegistry public immutable registry;
    address public immutable admin;

    address[3] public tokens;

    /// @dev Ghost accounting: cumulative allocated / released per token.
    mapping(address => uint256) public ghostAllocated;
    mapping(address => uint256) public ghostReleased;

    // Call counters, so we can prove the fuzzer actually exercised each path.
    uint256 public allocateCalls;
    uint256 public releaseCalls;
    uint256 public setCustodiedCalls;
    uint256 public skippedNoHeadroom;
    uint256 public skippedNothingAllocated;

    /// @dev Upper bound on recorded shares. Kept well below uint256 max so the
    ///      handler can never itself be the cause of an overflow -- if an
    ///      overflow shows up, it is the contract's fault, not the test's.
    uint256 internal constant MAX_CUSTODIED = 1e30;

    constructor(MockShareRegistry registry_, address admin_, address[3] memory tokens_) {
        registry = registry_;
        admin = admin_;
        tokens = tokens_;
    }

    function _token(uint256 seed) internal view returns (address) {
        return tokens[seed % tokens.length];
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZABLE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function allocate(uint256 tokenSeed, uint256 amount) external {
        address token = _token(tokenSeed);

        uint256 available = registry.availableShares(token);
        if (available == 0) {
            skippedNoHeadroom++;
            return;
        }

        amount = bound(amount, 1, available);

        vm.prank(token);
        registry.allocateShares(amount);

        ghostAllocated[token] += amount;
        allocateCalls++;
    }

    function release(uint256 tokenSeed, uint256 amount) external {
        address token = _token(tokenSeed);

        uint256 allocated = registry.allocatedShares(token);
        if (allocated == 0) {
            skippedNothingAllocated++;
            return;
        }

        amount = bound(amount, 1, allocated);

        vm.prank(token);
        registry.releaseShares(amount);

        ghostReleased[token] += amount;
        releaseCalls++;
    }

    /// @dev Always records at or above allocatedShares, so it never trips the
    ///      backing floor.
    function setCustodiedShares(uint256 tokenSeed, uint256 newCustodied) external {
        address token = _token(tokenSeed);

        uint256 allocated = registry.allocatedShares(token);
        newCustodied = bound(newCustodied, allocated, MAX_CUSTODIED);

        vm.prank(admin);
        registry.setCustodiedShares(token, newCustodied);

        setCustodiedCalls++;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            INVARIANT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract MockShareRegistryInvariantTest is ShareRegistryFixture {
    ShareRegistryHandler internal handler;
    address internal tokenC = makeAddr("tokenC");

    function setUp() public {
        _deployAndWire();

        vm.prank(admin);
        registry.registerToken(tokenC);

        handler = new ShareRegistryHandler(registry, admin, [tokenA, tokenB, tokenC]);

        // Seed initial backing so allocation is possible from run one.
        _setCustodied(tokenA, 1_000_000);
        _setCustodied(tokenB, 1_000_000);
        _setCustodied(tokenC, 1_000_000);

        // Admin power must sit with the handler for the duration of the run, so
        // its bounded setCustodiedShares action can execute.
        vm.prank(admin);
        registry.grantRole(ADMIN_ROLE, address(handler));

        // Only the handler may be called by the fuzzer; the registry is never
        // driven directly, so every state transition goes through a bounded,
        // ghost-tracked action.
        targetContract(address(handler));
    }

    function _tokens() internal view returns (address[3] memory) {
        return [tokenA, tokenB, tokenC];
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 1
    //////////////////////////////////////////////////////////////*/

    /// @notice allocatedShares <= custodiedShares, always. This is the backing
    ///         invariant: more share units must never be minted against a record
    ///         than the registry records as held.
    function invariant_allocatedNeverExceedsCustodied() public view {
        address[3] memory tokens = _tokens();
        for (uint256 i; i < tokens.length; ++i) {
            assertLe(
                registry.allocatedShares(tokens[i]), registry.custodiedShares(tokens[i]), "allocated exceeded custodied"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 2
    //////////////////////////////////////////////////////////////*/

    /// @notice availableShares == custodiedShares - allocatedShares, always, and
    ///         the subtraction never underflows. Because invariant 1 holds, this
    ///         call cannot revert; if it ever did, that is itself the failure.
    function invariant_availableSharesMatchesDifference() public view {
        address[3] memory tokens = _tokens();
        for (uint256 i; i < tokens.length; ++i) {
            uint256 custodied = registry.custodiedShares(tokens[i]);
            uint256 allocated = registry.allocatedShares(tokens[i]);
            assertEq(registry.availableShares(tokens[i]), custodied - allocated, "availableShares diverged");
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 3
    //////////////////////////////////////////////////////////////*/

    /// @notice Sum of all allocations minus sum of all releases equals the stored
    ///         allocatedShares. This is the "no value created or destroyed"
    ///         property for share allocation: the record can only ever be the net
    ///         of the flows that went through it.
    ///
    ///         It doubles as proof that changing the recorded backing never moves
    ///         allocation -- the handler calls setCustodiedShares thousands of
    ///         times, and if any of those shifted allocatedShares, the net-flow
    ///         equality would break. This is the direct ancestor of the property
    ///         the token itself must hold: a corporate action must not move share
    ///         ownership.
    function invariant_ghostFlowsMatchStoredAllocation() public view {
        address[3] memory tokens = _tokens();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 netFlow = handler.ghostAllocated(token) - handler.ghostReleased(token);
            assertEq(registry.allocatedShares(token), netFlow, "stored allocation diverged from net flow");
        }
    }

    /// @dev Not an invariant -- a run summary, so we can see the fuzzer actually
    ///      exercised every branch rather than silently skipping everything.
    function invariant_callSummary() public view {
        console.log("--- handler call summary ---");
        console.log("allocate              :", handler.allocateCalls());
        console.log("release               :", handler.releaseCalls());
        console.log("setCustodiedShares    :", handler.setCustodiedCalls());
        console.log("skipped: no headroom  :", handler.skippedNoHeadroom());
        console.log("skipped: nothing alloc:", handler.skippedNothingAllocated());
    }
}
