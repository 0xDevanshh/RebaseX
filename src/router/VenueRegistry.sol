// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title VenueRegistry
/// @notice Maps a `venueId` to the adapter contract that executes on that venue,
///         and keeps an enumerable set of the registered ids.
/// @dev SINGLE RESPONSIBILITY: `venueId -> trusted adapter address`, plus the list
///      of ids so callers can discover what exists. Deliberately contains no
///      venue-specific code, no token transfers, no swap or quote logic, no client
///      balances, and no settlement logic. It is a lookup table with access
///      control, and keeping it that way is what lets a new venue be added without
///      touching the Router.
///
///      WHY ENUMERATION EXISTS: an order with `venueId == bytes32(0)` means "best
///      execution", and the Router cannot compare venues it has no way to list.
///      The id set is what makes that resolvable.
///
///      ======================== SECURITY MODEL =========================
///      Adapter configuration is the most privileged operation in the routing
///      path. The Router will call whatever address this registry returns, so an
///      attacker able to write here could redirect execution to a contract of
///      their choosing and drain any funds routed through it. Writes are
///      therefore restricted to DEFAULT_ADMIN_ROLE; reads are open to everyone.
///
///      Only one role is used. A separate "venue manager" role would add a second
///      key to protect without reducing the blast radius of the first, since
///      DEFAULT_ADMIN_ROLE can grant itself any role anyway.
///      =================================================================
contract VenueRegistry is AccessControl {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice venueId of bytes32(0) is not a usable identifier.
    error InvalidVenueId();

    /// @notice Adapter address is not usable: zero, or holds no contract code.
    error InvalidAdapter();

    /// @notice No adapter is registered for this venueId.
    error VenueNotRegistered(bytes32 venueId);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an adapter is registered or replaced.
    /// @dev `oldAdapter` is address(0) on first registration, which is what
    ///      distinguishes a new venue from a replacement in the log.
    event AdapterSet(bytes32 indexed venueId, address indexed oldAdapter, address indexed newAdapter);

    /// @notice Emitted when a venue is removed.
    event AdapterRemoved(bytes32 indexed venueId, address indexed oldAdapter);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Private so the only address read path is {getAdapter}, which fails
    ///      loudly on an unregistered venue instead of returning address(0).
    mapping(bytes32 venueId => address adapter) private _adapters;

    /// @dev Registered ids, for enumeration only. The mapping remains the
    ///      authoritative record of whether a venue is usable; this set exists so
    ///      the ids can be listed.
    ///
    ///      INVARIANT: `_venueIds.contains(id)` iff `_adapters[id] != address(0)`.
    ///      Both are written in the same two functions and nowhere else, which is
    ///      what keeps them in step. {isRegistered} is derived from the MAPPING
    ///      rather than the set on purpose: it then states exactly "getAdapter will
    ///      succeed", so the two can never disagree even if the set were wrong.
    EnumerableSet.Bytes32Set private _venueIds;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param admin Address granted DEFAULT_ADMIN_ROLE. Rejected if zero, which
    ///              would otherwise leave the registry permanently unconfigurable.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new adapter for `venueId`, or replace the existing one.
    /// @dev Register and replace are one function on purpose: both write the same
    ///      slot, and splitting them would only add a way for the two paths to
    ///      drift apart. The emitted `oldAdapter` tells the two cases apart.
    /// @param venueId Venue identifier, e.g. keccak256("PANCAKE_V2").
    /// @param adapter Adapter implementing IVenueAdapter. Must hold contract code.
    function setAdapter(bytes32 venueId, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (venueId == bytes32(0)) revert InvalidVenueId();
        if (adapter == address(0)) revert InvalidAdapter();

        // The Router will call whatever address this returns, so an EOA or a
        // not-yet-deployed address would register cleanly and then fail at
        // settlement time — with a client's funds already in flight and a
        // confusing revert. Checking for code here converts a silent
        // misconfiguration into an immediate revert at configuration time, when
        // the only thing at stake is an admin transaction.
        //
        // This checks that code EXISTS, not that it is a correct adapter. A
        // contract with the wrong behaviour still registers; that is a review
        // problem, not something a registry can settle.
        if (adapter.code.length == 0) revert InvalidAdapter();

        address oldAdapter = _adapters[venueId];
        _adapters[venueId] = adapter;
        // No-op when the id is already present, which is the replacement case.
        _venueIds.add(venueId);

        emit AdapterSet(venueId, oldAdapter, adapter);
    }

    /// @notice Remove the adapter registered for `venueId`, disabling the venue.
    /// @dev Reverts if nothing is registered, so a removal that silently did
    ///      nothing cannot be mistaken for a successful one.
    /// @param venueId Venue identifier to remove.
    function removeAdapter(bytes32 venueId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdapter = _adapters[venueId];
        if (oldAdapter == address(0)) revert VenueNotRegistered(venueId);

        delete _adapters[venueId];
        _venueIds.remove(venueId);

        emit AdapterRemoved(venueId, oldAdapter);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adapter registered for `venueId`.
    /// @dev Reverts rather than returning address(0) for an unknown venue. A
    ///      zero-address return would be a value the caller has to remember to
    ///      check, and forgetting would mean the Router calling address(0); a
    ///      revert makes the mistake impossible.
    /// @param venueId Venue identifier to resolve.
    /// @return adapter Registered adapter address.
    function getAdapter(bytes32 venueId) external view returns (address adapter) {
        adapter = _adapters[venueId];
        if (adapter == address(0)) revert VenueNotRegistered(venueId);
    }

    /// @notice Whether `venueId` has an adapter registered.
    /// @dev NEVER REVERTS, and that is the whole point of it existing alongside
    ///      {getAdapter}. The two coexist deliberately and serve opposite needs:
    ///
    ///        - {getAdapter} is the EXECUTION path. The caller has already decided
    ///          which venue to use, so an unknown id is a failure and must revert
    ///          rather than hand back address(0).
    ///        - {isRegistered} is the DISCOVERY path. A best-execution loop needs
    ///          to probe venues to decide which one to use, and a revert there
    ///          would abort the whole comparison instead of skipping one candidate.
    ///
    ///      Returns exactly the condition under which {getAdapter} succeeds, so a
    ///      caller can never be told a venue is usable and then be reverted on.
    /// @param venueId Venue identifier to probe.
    function isRegistered(bytes32 venueId) external view returns (bool) {
        return _adapters[venueId] != address(0);
    }

    /// @notice Number of registered venues.
    function venueCount() external view returns (uint256) {
        return _venueIds.length();
    }

    /// @notice Venue id at `index`.
    /// @dev ORDER IS NOT STABLE. Removal uses swap-and-pop, so removing a venue
    ///      moves the last id into the vacated slot. Callers must not treat an
    ///      index as a durable handle to a venue, and must not assume insertion
    ///      order. Reverts if `index` is out of range.
    /// @param index Position in the id set, `0 <= index < venueCount()`.
    function venueIdAt(uint256 index) external view returns (bytes32) {
        return _venueIds.at(index);
    }

    /// @notice All registered venue ids.
    /// @dev UNBOUNDED: cost grows linearly with the number of venues, and the
    ///      whole array is copied into memory. Intended for off-chain reads,
    ///      scripts, and tests.
    ///
    ///      Do NOT call this from an on-chain hot path such as a settlement or
    ///      best-execution loop. Use {venueCount} with {venueIdAt} to iterate
    ///      without materialising the array, and prefer bounding the number of
    ///      venues a single order may consider so gas stays predictable.
    function allVenueIds() external view returns (bytes32[] memory) {
        return _venueIds.values();
    }
}
