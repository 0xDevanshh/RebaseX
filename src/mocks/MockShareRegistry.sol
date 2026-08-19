// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IShareRegistry} from "../interfaces/IShareRegistry.sol";

/// @title MockShareRegistry
/// @notice Mock underlying-share registry backing the 1:1 primary mint/redeem
///         path of a rebasing tokenised-equity token. It records how many
///         underlying share units exist for a token and how many have been
///         minted against them, and nothing else.
/// @dev SCOPE. This is deliberately minimal: the only job it does beyond
///      bookkeeping is refusing to let a token mint more share units than the
///      registry records. It does NOT model custody attestations, attestation
///      freshness, or an oracle feed — that is the optional Part B "Proof of
///      Collateral" feature, which this project does not implement (Part B here
///      is Primary vs Secondary Routing). Adding an attestation layer would be
///      a strict superset of this contract and belongs behind that feature, not
///      in the Part A path.
///
///      ============================ INVARIANT ============================
///      THIS CONTRACT STORES SHARES ONLY.
///
///      It must never store, accept, return, or compute a multiplier-scaled
///      token balance. There is deliberately no rebase multiplier, no 1e18
///      scaling constant, and no division anywhere in this file. Share backing
///      is kept strictly separate from the rebase multiplier: the multiplier
///      lives on the token and governs how many *tokens* a share unit is worth,
///      never how many share units exist.
///
///      Consequence: applying a corporate action on the equity token is a
///      COMPLETE NO-OP for this contract's state. `custodiedShares` and
///      `allocatedShares` are invariant under any change to the token's
///      multiplier.
///
///      Any future change that introduces a multiplier here is a bug: it would
///      couple share backing to a value that moves for reasons unrelated to the
///      underlying, and would let a rebase appear to create or destroy backing.
///      ===================================================================
///
///      ========================= SECURITY MODEL =========================
///      NO EXTERNAL CALLS. This contract makes zero calls out — no token
///      transfers, no callbacks, no hooks, no oracle reads. Every function
///      reads and writes only its own storage and emits events.
///
///      That is the entire reentrancy argument: there is no reentrancy surface
///      because there is no external call from which control could return.
///      Nothing here can be re-entered mid-update, so no ReentrancyGuard is
///      used — adding one would cost storage and gas to defend against a call
///      pattern the code cannot produce. The property worth protecting is the
///      absence of external calls itself: if a future change introduces one,
///      this argument dies with it and the guard must be revisited.
///
///      Token-facing accounting is SELF-KEYED — see {allocateShares}.
///      ==================================================================
contract MockShareRegistry is IShareRegistry, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-token share record. Keyed by token address so a second
    ///         tokenised equity can be added without redeploying this registry.
    mapping(address token => ShareRecord) private _records;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param admin Address granted DEFAULT_ADMIN_ROLE, standing in for the
    ///              party that maintains the underlying-share record.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          TOKEN-FACING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve `shareAmount` share units against the caller's own record.
    /// @dev SELF-KEYED AUTHORIZATION. There is no MINTER_ROLE. The record is
    ///      keyed by msg.sender, so the caller's identity *is* its authorization:
    ///      a token can only ever mutate the record it is itself keyed to.
    ///
    ///      WHY THIS IS STRONGER THAN A ROLE: a role is a grant, and grants can
    ///      be misconfigured. With `allocateShares(address token, uint256)` +
    ///      a MINTER_ROLE, any holder of that role could allocate against *any*
    ///      registered token's record — so one bad grant, one compromised token,
    ///      or one copy-paste error in a deploy script lets token A consume
    ///      token B's share backing and quietly undercollateralise it. There is
    ///      no such grant here, and no address to compromise: cross-token
    ///      allocation is not merely forbidden, it is unexpressible, because the
    ///      function takes no token argument to point at another record.
    ///
    ///      Cost of this choice: only the token contract itself can allocate, so
    ///      there is no admin override to repair a stuck allocation. That is the
    ///      intended trade — the registry's figures should only ever move as a
    ///      consequence of real mint/redeem flow, never by hand.
    /// @param shareAmount Share units to allocate.
    function allocateShares(uint256 shareAmount) external {
        ShareRecord storage record = _records[msg.sender];

        if (!record.registered) revert NotRegistered(msg.sender);
        if (shareAmount == 0) revert ZeroAmount();

        uint256 available = _availableShares(record);
        if (shareAmount > available) revert InsufficientAvailableShares(shareAmount, available);

        uint256 newAllocated = record.allocatedShares + shareAmount;
        record.allocatedShares = newAllocated;

        emit SharesAllocated(msg.sender, shareAmount, newAllocated, record.custodiedShares - newAllocated);
    }

    /// @notice Release `shareAmount` share units from the caller's own record.
    /// @dev Self-keyed for the same reason as {allocateShares}. Release only
    ///      reduces an existing claim, so it can never breach the
    ///      allocated <= custodied invariant.
    /// @param shareAmount Share units to release.
    function releaseShares(uint256 shareAmount) external {
        ShareRecord storage record = _records[msg.sender];

        if (!record.registered) revert NotRegistered(msg.sender);
        if (shareAmount == 0) revert ZeroAmount();

        uint256 allocated = record.allocatedShares;
        if (shareAmount > allocated) revert InsufficientAllocatedShares(shareAmount, allocated);

        uint256 newAllocated = allocated - shareAmount;
        record.allocatedShares = newAllocated;

        emit SharesReleased(msg.sender, shareAmount, newAllocated, record.custodiedShares - newAllocated);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IShareRegistry
    function registerToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();

        ShareRecord storage record = _records[token];
        if (record.registered) revert AlreadyRegistered(token);

        record.registered = true;

        emit TokenRegistered(token);
    }

    /// @notice Set the underlying share units recorded as held for `token`.
    /// @dev The figure may not be set below `allocatedShares`.
    ///
    ///      WHY: `allocatedShares` is what has already been minted and is in
    ///      circulation. Accepting a figure beneath it would, in a single call,
    ///      move the token into an unbacked state — tokens exist that no
    ///      underlying share unit backs — with no remediation path available
    ///      from this contract. The registry cannot burn a holder's tokens, so
    ///      the shortfall would simply persist while minting stayed open on any
    ///      remaining headroom. Redemptions must be driven down first, so that
    ///      `allocatedShares` falls to the level being recorded, and only then
    ///      may the figure be lowered.
    ///
    ///      TRADE-OFF (known limitation): this means a genuine loss of
    ///      underlying shares cannot be recorded honestly through this function
    ///      while tokens are outstanding. The registry keeps reporting backing
    ///      that is known to be absent, and the floor is enforced by the very
    ///      party that would need to report the loss. A production system needs
    ///      a separate privileged path — declare a shortfall, freeze minting,
    ///      and socialise the loss across holders (e.g. via a downward corporate
    ///      action on the token) rather than hiding it behind a rejected write.
    ///      Carried into the written submission as a known limitation.
    /// @param token              Address of the registered token.
    /// @param newCustodiedShares Total underlying share units held.
    function setCustodiedShares(address token, uint256 newCustodiedShares) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ShareRecord storage record = _records[token];
        if (!record.registered) revert NotRegistered(token);

        uint256 allocated = record.allocatedShares;
        if (newCustodiedShares < allocated) {
            revert CustodiedBelowAllocated(newCustodiedShares, allocated);
        }

        uint256 previousCustodied = record.custodiedShares;
        record.custodiedShares = newCustodiedShares;

        emit CustodiedSharesUpdated(token, previousCustodied, newCustodiedShares, allocated);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IShareRegistry
    function custodiedShares(address token) external view returns (uint256) {
        return _records[token].custodiedShares;
    }

    /// @inheritdoc IShareRegistry
    function allocatedShares(address token) external view returns (uint256) {
        return _records[token].allocatedShares;
    }

    /// @inheritdoc IShareRegistry
    /// @dev Cannot underflow: {setCustodiedShares} refuses to drop
    ///      `custodiedShares` below `allocatedShares`, and {allocateShares}
    ///      refuses to raise `allocatedShares` above `custodiedShares`.
    function availableShares(address token) external view returns (uint256) {
        return _availableShares(_records[token]);
    }

    /// @inheritdoc IShareRegistry
    function isRegistered(address token) external view returns (bool) {
        return _records[token].registered;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Shared by {availableShares} and {allocateShares} so the allocation
    ///      path never calls out into this contract's own public view — see the
    ///      SECURITY MODEL note on the absence of external calls.
    function _availableShares(ShareRecord storage record) private view returns (uint256) {
        return record.custodiedShares - record.allocatedShares;
    }
}
