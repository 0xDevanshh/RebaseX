// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {VenueRegistry} from "../src/router/VenueRegistry.sol";
import {IVenueAdapter} from "../src/interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

/// @dev Minimal stand-in adapter. The registry only requires that the address
///      holds contract code -- it does not and cannot verify behaviour -- but
///      implementing the real interface keeps the fixture honest about what a
///      registered address is meant to be.
contract StubVenueAdapter is IVenueAdapter {
    function quote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function swap(OrderTypes.Order calldata, address) external pure returns (uint256) {
        return 0;
    }
}

contract VenueRegistryTest is Test {
    VenueRegistry internal venues;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    /// @dev Real contracts, because {setAdapter} rejects addresses without code.
    address internal adapterA;
    address internal adapterB;
    address internal adapterC;

    bytes32 internal constant PANCAKE_V2 = keccak256("PANCAKE_V2");
    bytes32 internal constant FUTURE_VENUE = keccak256("FUTURE_VENUE");

    /// @dev Hardcoded rather than read from the contract: a getter call would be an
    ///      external call that consumes a pending `vm.prank`, and a test should not
    ///      assert a contract against its own getter.
    bytes32 internal constant ADMIN_ROLE = 0x00;

    function setUp() public {
        venues = new VenueRegistry(admin);
        adapterA = address(new StubVenueAdapter());
        adapterB = address(new StubVenueAdapter());
        adapterC = address(new StubVenueAdapter());
    }

    function _setAdapter(bytes32 venueId, address adapter) internal {
        vm.prank(admin);
        venues.setAdapter(venueId, adapter);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_initialState_adminHasAdminRole() public view {
        assertTrue(venues.hasRole(ADMIN_ROLE, admin));
    }

    function test_initialState_strangerHasNoRole() public view {
        assertFalse(venues.hasRole(ADMIN_ROLE, stranger));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(VenueRegistry.ZeroAddress.selector);
        new VenueRegistry(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_setAdapter_registersAndResolves() public {
        _setAdapter(PANCAKE_V2, adapterA);
        assertEq(venues.getAdapter(PANCAKE_V2), adapterA);
    }

    /// @dev On first registration `oldAdapter` is address(0), which is how a new
    ///      venue is distinguished from a replacement in the log.
    function test_event_setAdapter_onFirstRegistration() public {
        vm.expectEmit(true, true, true, true, address(venues));
        emit VenueRegistry.AdapterSet(PANCAKE_V2, address(0), adapterA);

        vm.prank(admin);
        venues.setAdapter(PANCAKE_V2, adapterA);
    }

    /*//////////////////////////////////////////////////////////////
                                 UPDATE
    //////////////////////////////////////////////////////////////*/

    function test_setAdapter_replacesExistingAdapter() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(PANCAKE_V2, adapterB);

        assertEq(venues.getAdapter(PANCAKE_V2), adapterB, "should resolve to the new adapter");
    }

    function test_event_setAdapter_onReplacementCarriesOldAndNew() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.expectEmit(true, true, true, true, address(venues));
        emit VenueRegistry.AdapterSet(PANCAKE_V2, adapterA, adapterB);

        vm.prank(admin);
        venues.setAdapter(PANCAKE_V2, adapterB);
    }

    /// @dev Re-setting the same adapter is permitted and is a no-op in effect. It
    ///      still emits, so configuration replays stay visible on-chain.
    function test_setAdapter_sameAdapterTwiceIsAllowed() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.expectEmit(true, true, true, true, address(venues));
        emit VenueRegistry.AdapterSet(PANCAKE_V2, adapterA, adapterA);

        vm.prank(admin);
        venues.setAdapter(PANCAKE_V2, adapterA);

        assertEq(venues.getAdapter(PANCAKE_V2), adapterA);
    }

    /*//////////////////////////////////////////////////////////////
                                REMOVAL
    //////////////////////////////////////////////////////////////*/

    function test_removeAdapter_disablesVenue() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);

        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, PANCAKE_V2));
        venues.getAdapter(PANCAKE_V2);
    }

    function test_event_removeAdapter() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.expectEmit(true, true, true, true, address(venues));
        emit VenueRegistry.AdapterRemoved(PANCAKE_V2, adapterA);

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);
    }

    /// @dev A removed venue can be registered again afterwards.
    function test_removeAdapter_thenReRegister() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);

        _setAdapter(PANCAKE_V2, adapterC);
        assertEq(venues.getAdapter(PANCAKE_V2), adapterC);
    }

    function test_revert_removeAdapter_unregisteredVenue() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, PANCAKE_V2));
        venues.removeAdapter(PANCAKE_V2);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice The load-bearing access-control test: if a non-admin could set an
    ///         adapter, they could redirect Router execution to a contract they
    ///         control.
    function test_revert_setAdapter_fromNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        venues.setAdapter(PANCAKE_V2, adapterA);
    }

    function test_revert_removeAdapter_fromNonAdmin() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        venues.removeAdapter(PANCAKE_V2);
    }

    /// @dev A failed unauthorized write must leave configuration untouched.
    function test_revert_setAdapter_fromNonAdminLeavesStateIntact() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.prank(stranger);
        vm.expectRevert();
        venues.setAdapter(PANCAKE_V2, adapterB);

        assertEq(venues.getAdapter(PANCAKE_V2), adapterA, "state changed on failed write");
    }

    /// @dev Reads are permissionless -- anyone may resolve a venue.
    function test_getAdapter_isPermissionless() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.prank(stranger);
        assertEq(venues.getAdapter(PANCAKE_V2), adapterA);
    }

    /*//////////////////////////////////////////////////////////////
                              VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_revert_setAdapter_zeroVenueId() public {
        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidVenueId.selector);
        venues.setAdapter(bytes32(0), adapterA);
    }

    function test_revert_setAdapter_zeroAdapter() public {
        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidAdapter.selector);
        venues.setAdapter(PANCAKE_V2, address(0));
    }

    /// @dev Zeroing an adapter is not a backdoor removal path; removal is explicit.
    function test_revert_setAdapter_zeroAdapterOnExistingVenue() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidAdapter.selector);
        venues.setAdapter(PANCAKE_V2, address(0));

        assertEq(venues.getAdapter(PANCAKE_V2), adapterA, "venue should be untouched");
    }

    function test_revert_getAdapter_unknownVenue() public {
        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, FUTURE_VENUE));
        venues.getAdapter(FUTURE_VENUE);
    }

    /*//////////////////////////////////////////////////////////////
                          ISOLATION BETWEEN VENUES
    //////////////////////////////////////////////////////////////*/

    /// @notice Configuring one venue must never affect another. This is what makes
    ///         adding a venue a safe operation rather than a risky one.
    function test_isolation_updatingOneVenueLeavesOtherUnchanged() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterB);

        _setAdapter(PANCAKE_V2, adapterC); // update only PANCAKE_V2

        assertEq(venues.getAdapter(PANCAKE_V2), adapterC, "PANCAKE_V2 should be updated");
        assertEq(venues.getAdapter(FUTURE_VENUE), adapterB, "FUTURE_VENUE should be untouched");
    }

    function test_isolation_removingOneVenueLeavesOtherUnchanged() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterB);

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);

        assertEq(venues.getAdapter(FUTURE_VENUE), adapterB, "FUTURE_VENUE should be untouched");

        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, PANCAKE_V2));
        venues.getAdapter(PANCAKE_V2);
    }

    /// @dev The same adapter may serve two venueIds; the registry maps ids to
    ///      addresses and does not require them to be distinct.
    function test_isolation_sameAdapterOnTwoVenues() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterA);

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);

        assertEq(venues.getAdapter(FUTURE_VENUE), adapterA, "shared adapter should survive");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Any non-zero id round-trips through the registry, for an arbitrary
    ///         address that holds code.
    function testFuzz_setAndGetAdapter(bytes32 venueId, address adapter) public {
        vm.assume(venueId != bytes32(0));
        _assumeEtchable(adapter);
        vm.etch(adapter, hex"6001600155"); // give the fuzzed address some code

        _setAdapter(venueId, adapter);

        assertEq(venues.getAdapter(venueId), adapter);
        assertTrue(venues.isRegistered(venueId));
        assertEq(venues.venueCount(), 1);
    }

    /// @notice Writing one venue never makes an unrelated venue resolvable.
    function testFuzz_unrelatedVenueStaysUnregistered(bytes32 venueId, bytes32 otherId) public {
        vm.assume(venueId != bytes32(0) && otherId != bytes32(0));
        vm.assume(venueId != otherId);

        _setAdapter(venueId, adapterA);

        assertFalse(venues.isRegistered(otherId), "unrelated venue must not be registered");

        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, otherId));
        venues.getAdapter(otherId);
    }

    /// @notice Any address without code is rejected, whoever it is.
    function testFuzz_revert_setAdapter_addressWithoutCode(address adapter) public {
        vm.assume(adapter != address(0));
        vm.assume(adapter.code.length == 0);

        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidAdapter.selector);
        venues.setAdapter(PANCAKE_V2, adapter);
    }

    /// @dev Keeps the fuzzer from etching over addresses the test depends on.
    function _assumeEtchable(address target) internal view {
        vm.assume(target != address(0));
        vm.assume(target != address(venues));
        vm.assume(target != address(this));
        vm.assume(target != adapterA && target != adapterB && target != adapterC);
        vm.assume(target > address(0x20)); // avoid precompiles
        vm.assume(target.code.length == 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ADAPTER CODE CHECK (FIX 2)
    //////////////////////////////////////////////////////////////*/

    /// @notice An EOA must not register. Without this check it would register
    ///         cleanly and fail only at settlement, with client funds in flight.
    function test_revert_setAdapter_eoaHasNoCode() public {
        address eoa = makeAddr("someEOA");
        assertEq(eoa.code.length, 0, "fixture should be an EOA");

        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidAdapter.selector);
        venues.setAdapter(PANCAKE_V2, eoa);
    }

    /// @notice An address that is merely *planned* to hold a contract is rejected.
    function test_revert_setAdapter_undeployedAddress() public {
        address notYetDeployed = vm.computeCreateAddress(admin, 0);

        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidAdapter.selector);
        venues.setAdapter(PANCAKE_V2, notYetDeployed);
    }

    /// @dev A failed code check must not partially register the venue.
    function test_revert_setAdapter_noCodeLeavesVenueUnregistered() public {
        address eoa = makeAddr("someEOA");

        vm.prank(admin);
        vm.expectRevert(VenueRegistry.InvalidAdapter.selector);
        venues.setAdapter(PANCAKE_V2, eoa);

        assertFalse(venues.isRegistered(PANCAKE_V2));
        assertEq(venues.venueCount(), 0, "id set must not have grown");
    }

    /*//////////////////////////////////////////////////////////////
                        ENUMERATION (FIX 1)
    //////////////////////////////////////////////////////////////*/

    function test_enumeration_emptyOnDeployment() public view {
        assertEq(venues.venueCount(), 0);
        assertEq(venues.allVenueIds().length, 0);
    }

    function test_enumeration_countsRegisteredVenues() public {
        _setAdapter(PANCAKE_V2, adapterA);
        assertEq(venues.venueCount(), 1);

        _setAdapter(FUTURE_VENUE, adapterB);
        assertEq(venues.venueCount(), 2);
    }

    /// @dev Replacing an adapter must not duplicate the id in the set.
    function test_enumeration_replacementDoesNotGrowSet() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(PANCAKE_V2, adapterB);
        _setAdapter(PANCAKE_V2, adapterC);

        assertEq(venues.venueCount(), 1, "id should appear once");
        assertEq(venues.allVenueIds().length, 1);
        assertEq(venues.getAdapter(PANCAKE_V2), adapterC);
    }

    function test_enumeration_removalShrinksSet() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterB);

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);

        assertEq(venues.venueCount(), 1);

        bytes32[] memory ids = venues.allVenueIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], FUTURE_VENUE, "the surviving venue should remain");
    }

    function test_enumeration_allVenueIdsContainsBothVenues() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterB);

        bytes32[] memory ids = venues.allVenueIds();
        assertEq(ids.length, 2);

        // Order is not part of the contract, so check membership rather than index.
        bool sawPancake;
        bool sawFuture;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == PANCAKE_V2) sawPancake = true;
            if (ids[i] == FUTURE_VENUE) sawFuture = true;
        }
        assertTrue(sawPancake && sawFuture, "both ids should be listed");
    }

    function test_enumeration_venueIdAtMatchesAllVenueIds() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterB);

        bytes32[] memory ids = venues.allVenueIds();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(venues.venueIdAt(i), ids[i], "indexed read should match the array");
        }
    }

    function test_revert_venueIdAt_outOfRange() public {
        _setAdapter(PANCAKE_V2, adapterA);

        vm.expectRevert();
        venues.venueIdAt(1);
    }

    /// @notice Enumeration and resolution must never disagree: every listed id
    ///         resolves, and reports as registered. This is the mapping/set
    ///         consistency invariant stated in the contract.
    function test_enumeration_everyListedIdResolves() public {
        _setAdapter(PANCAKE_V2, adapterA);
        _setAdapter(FUTURE_VENUE, adapterB);
        _setAdapter(keccak256("THIRD"), adapterC);

        vm.prank(admin);
        venues.removeAdapter(FUTURE_VENUE); // exercise swap-and-pop

        bytes32[] memory ids = venues.allVenueIds();
        assertEq(ids.length, 2);

        for (uint256 i; i < ids.length; ++i) {
            assertTrue(venues.isRegistered(ids[i]), "listed id must report registered");
            assertTrue(venues.getAdapter(ids[i]) != address(0), "listed id must resolve");
        }

        assertFalse(venues.isRegistered(FUTURE_VENUE), "removed id must not report registered");
    }

    /*//////////////////////////////////////////////////////////////
                    isRegistered: THE NON-REVERTING PROBE
    //////////////////////////////////////////////////////////////*/

    function test_isRegistered_trueAfterRegistration() public {
        _setAdapter(PANCAKE_V2, adapterA);
        assertTrue(venues.isRegistered(PANCAKE_V2));
    }

    /// @notice THE POINT OF THIS FUNCTION: a best-execution loop must be able to
    ///         probe an unknown venue without the whole comparison reverting.
    ///         `getAdapter` reverts on the same input; both behaviours are wanted.
    function test_isRegistered_falseForUnknownVenueAndDoesNotRevert() public view {
        assertFalse(venues.isRegistered(FUTURE_VENUE));
    }

    function test_isRegistered_falseForZeroVenueId() public view {
        assertFalse(venues.isRegistered(bytes32(0)));
    }

    function test_isRegistered_falseAfterRemoval() public {
        _setAdapter(PANCAKE_V2, adapterA);
        assertTrue(venues.isRegistered(PANCAKE_V2));

        vm.prank(admin);
        venues.removeAdapter(PANCAKE_V2);

        assertFalse(venues.isRegistered(PANCAKE_V2));
    }

    /// @dev The two read paths must agree: whenever isRegistered is false,
    ///      getAdapter reverts, and whenever true, getAdapter succeeds.
    function test_isRegistered_agreesWithGetAdapter() public {
        assertFalse(venues.isRegistered(PANCAKE_V2));
        vm.expectRevert(abi.encodeWithSelector(VenueRegistry.VenueNotRegistered.selector, PANCAKE_V2));
        venues.getAdapter(PANCAKE_V2);

        _setAdapter(PANCAKE_V2, adapterA);

        assertTrue(venues.isRegistered(PANCAKE_V2));
        assertEq(venues.getAdapter(PANCAKE_V2), adapterA);
    }
}
