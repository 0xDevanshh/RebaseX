// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IClientAccount} from "../interfaces/IClientAccount.sol";
import {ISettlementEngine} from "../interfaces/ISettlementEngine.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";
import {VenueRegistry} from "../router/VenueRegistry.sol";

/// @title Router
/// @notice Stateless orchestration entry point for trade requests.
/// @dev ROUTER PERFORMS ORCHESTRATION ONLY. ALL FUND MOVEMENT BELONGS TO
///      SETTLEMENTENGINE.
///
///      The flow is:
///
///          receive Order -> validate + authorize -> resolve venue
///                        -> delegate to SettlementEngine -> emit attribution
///
///      What this contract deliberately does NOT do: hold client balances, call
///      `transfer` or `transferFrom`, approve anything, capture fees, execute a
///      swap, or enforce slippage. It has no mapping of orders, no used-hash set,
///      no nonces, no client records, and no fee balances. Its only storage is two
///      immutable addresses.
///
///      Why that matters beyond tidiness: a contract that holds no balances and
///      records no client state cannot be drained and cannot desynchronise from
///      the settlement layer. It reduces the Router to a decision-maker, so the
///      security review of "can client funds be lost" concentrates entirely on
///      the settlement engine and the client account.
///
///      ================ WHY THE DEPENDENCIES ARE IMMUTABLE ==============
///      `settlementEngine` is the address every order's funds flow through. A
///      mutable pointer would mean whoever could write it could redirect all
///      future orders into settlement logic of their choosing — the single most
///      valuable write in the system.
///
///      So there is no setter and no proxy. Replacing the settlement engine means
///      deploying a new Router, which gives clients a NEW ADDRESS they must
///      consciously approve and use. A silent swap behind a familiar address is
///      exactly the change a client cannot detect; a new address is one they
///      cannot miss. This is the on-chain form of "clients can exit before a
///      privileged change takes effect": the change cannot reach anyone who does
///      not opt in.
///      ==================================================================
contract Router is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is neither the account nor one of its operators.
    error UnauthorizedCaller();

    /// @notice Order deadline is in the past.
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);

    /// @notice Order input amount is zero.
    error ZeroAmount();

    /// @notice Order specifies no minimum output. See {submitOrder} for policy.
    error ZeroMinAmountOut();

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice assetIn and assetOut are the same token.
    error IdenticalAssets();

    /// @notice Best execution found no venue able to quote this pair.
    error NoVenueAvailable();

    /// @notice More venues are registered than best execution will scan.
    error TooManyVenues(uint256 count, uint256 maximum);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an order passes validation, before delegation.
    /// @dev `submitter` is recorded separately from `account` because they differ
    ///      whenever an operator trades on a client's behalf. Off-chain fill
    ///      attribution needs both: `account` owns the position, `submitter` is who
    ///      acted, and only keeping one of them makes operator activity
    ///      unauditable.
    /// @param venueId The venue as SUBMITTED — `bytes32(0)` means best execution.
    ///                See {OrderRouted} for the venue actually chosen.
    event OrderSubmitted(
        bytes32 indexed orderHash,
        address indexed account,
        address indexed submitter,
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes32 venueId,
        uint256 deadline
    );

    /// @notice Emitted after settlement succeeds.
    /// @dev Emitted only on success. If settlement reverts the whole transaction
    ///      reverts with it, so {OrderSubmitted} is discarded too — a failed
    ///      settlement therefore persists NO Router logs at all. Anyone
    ///      reconstructing fills off-chain sees only completed orders, and should
    ///      not expect a submitted-without-routed pair to indicate a failure.
    /// @param indicativeQuote The winning quote for a best-execution order, or 0
    ///                        for an explicit-venue order, which is not quoted.
    /// @param amountOut       Amount settlement actually delivered.
    event OrderRouted(
        bytes32 indexed orderHash,
        bytes32 indexed resolvedVenueId,
        address indexed adapter,
        uint256 indicativeQuote,
        uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard cap on venues inspected during best execution.
    /// @dev Best execution makes one external `quote` call per venue, so its gas
    ///      cost grows with the registry. Left unbounded, adding venues would
    ///      eventually push `submitOrder` past the block gas limit and break every
    ///      best-execution order at once — a liveness failure introduced by an
    ///      unrelated admin action. The cap converts that into an explicit,
    ///      immediate revert instead.
    uint256 public constant MAX_VENUES_SCANNED = 16;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Registry resolving a venueId to its adapter.
    VenueRegistry public immutable venueRegistry;

    /// @notice Engine that performs all fund movement for a routed order.
    ISettlementEngine public immutable settlementEngine;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param venueRegistry_    Venue registry. Immutable once set.
    /// @param settlementEngine_ Settlement engine. Immutable once set.
    constructor(VenueRegistry venueRegistry_, ISettlementEngine settlementEngine_) {
        if (address(venueRegistry_) == address(0)) revert ZeroAddress();
        if (address(settlementEngine_) == address(0)) revert ZeroAddress();

        venueRegistry = venueRegistry_;
        settlementEngine = settlementEngine_;
    }

    /*//////////////////////////////////////////////////////////////
                              ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    /// @notice Validate, route, and settle `o`.
    /// @dev ORDER OF CHECKS IS DELIBERATE: the account is checked for zero first so
    ///      authorization never has to reason about `address(0)`, then
    ///      authorization, then the order's own fields. Authorization comes before
    ///      field validation so an unauthorized caller learns nothing about which
    ///      fields of someone else's order would have been acceptable.
    ///
    ///      POLICY: `minAmountOut == 0` is rejected. A zero floor is unlimited
    ///      slippage, which is not a trade instruction so much as an invitation to
    ///      be sandwiched for the full value of the input. Refusing it means a
    ///      client cannot lose everything to a typo or a forgotten field, at the
    ///      cost of not supporting genuinely unbounded market orders — which this
    ///      system has no reason to support.
    ///
    ///      REENTRANCY: guarded because this makes an external state-changing call
    ///      into `settlementEngine.settle`, which moves tokens and can therefore
    ///      hand control to arbitrary code (a token hook, an adapter, a recipient).
    ///      Without the guard, that code could re-enter `submitOrder` and interleave
    ///      a second orchestration inside the first. The Router holds no funds, so
    ///      this is not protecting a balance; it is keeping one order's flow
    ///      indivisible so events, resolution, and settlement cannot be interleaved
    ///      into an order of operations no one designed or tested. The `quote` calls
    ///      are views and are NOT the reason for the guard.
    ///
    ///      NOT REPLAY PROTECTION: this contract stores nothing about past orders,
    ///      so an identical, still-valid, still-authorized order can be submitted
    ///      again while allowance and funds remain. See {submitOrder} note on
    ///      `orderHash`.
    /// @param o The order to execute.
    /// @return amountOut Amount of `o.assetOut` delivered by settlement.
    function submitOrder(OrderTypes.Order calldata o) external nonReentrant returns (uint256 amountOut) {
        if (o.account == address(0)) revert ZeroAddress();

        _authorize(o.account);
        _validateOrder(o);

        // Log correlation handle ONLY. This is not a nonce, not replay protection,
        // not a signature digest, and not a record that the order executed — the
        // Router keeps no set of used hashes. Two identical orders produce the same
        // hash by design, which is what makes it useful for grouping logs and
        // useless for preventing repeats.
        bytes32 orderHash = keccak256(abi.encode(o));

        emit OrderSubmitted(
            orderHash, o.account, msg.sender, o.assetIn, o.assetOut, o.amountIn, o.minAmountOut, o.venueId, o.deadline
        );

        (bytes32 resolvedVenueId, address adapter, uint256 indicativeQuote) = _resolveVenue(o);

        // Everything that touches value happens behind this one call. The Router
        // does not transfer, approve, take a fee, or re-check slippage.
        amountOut = settlementEngine.settle(o, resolvedVenueId, adapter);

        emit OrderRouted(orderHash, resolvedVenueId, adapter, indicativeQuote, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev THREAT MODEL — this is the check that makes the Router safe to expose.
    ///      Settlement will move funds belonging to `account`, drawing on an
    ///      allowance that account has already granted. Without this check, ANY
    ///      caller could submit orders on any account's behalf and consume that
    ///      standing allowance — routing a victim's assets into a venue and a
    ///      trade of the attacker's choosing. The funds would never touch the
    ///      Router, which is precisely why "the Router holds no balances" is not by
    ///      itself a sufficient safety argument.
    ///
    ///      An EOA account can only authorize itself: it has no code, so it cannot
    ///      express an operator relationship. Probing it with a call would return
    ///      empty data and decode into a confusing low-level failure, so the
    ///      code-length check short-circuits to a clear `UnauthorizedCaller`.
    ///
    ///      For contract accounts the probe is wrapped in try/catch so a contract
    ///      that does not implement {IClientAccount} — or reverts, or returns
    ///      undecodable data — is treated as "not authorized" rather than surfacing
    ///      an ABI decoding error. Failing closed is the only safe default for an
    ///      authorization question.
    function _authorize(address account) private view {
        if (msg.sender == account) return;

        if (account.code.length == 0) revert UnauthorizedCaller();

        try IClientAccount(account).isOperator(msg.sender) returns (bool authorized) {
            if (!authorized) revert UnauthorizedCaller();
        } catch {
            revert UnauthorizedCaller();
        }
    }

    /// @dev Field validation. `deadline == block.timestamp` is still valid: the
    ///      order expires after its deadline, not on it.
    function _validateOrder(OrderTypes.Order calldata o) private view {
        if (o.deadline < block.timestamp) revert DeadlineExpired(o.deadline, block.timestamp);
        if (o.amountIn == 0) revert ZeroAmount();
        if (o.minAmountOut == 0) revert ZeroMinAmountOut();
        if (o.assetIn == address(0) || o.assetOut == address(0)) revert ZeroAddress();
        if (o.assetIn == o.assetOut) revert IdenticalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: VENUE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolves the venue to execute on.
    ///
    ///      QUOTES ARE INDICATIVE ONLY. The figures compared here are view reads of
    ///      venue state at this instant. By the time settlement executes, the pool
    ///      may have moved — through ordinary trading, through a sandwich built
    ///      around this very transaction, or, for the rebasing equity token,
    ///      through a corporate action. A quote is therefore a routing signal for
    ///      choosing BETWEEN venues, never a promise about what will be received.
    ///      The only binding protection is `minAmountOut`, enforced by the
    ///      settlement engine against the amount actually realised.
    /// @return resolvedVenueId Concrete venue chosen, never zero on success.
    /// @return adapter         Adapter registered for `resolvedVenueId`.
    /// @return indicativeQuote Winning quote, or 0 for an explicit venue.
    function _resolveVenue(OrderTypes.Order calldata o)
        private
        view
        returns (bytes32 resolvedVenueId, address adapter, uint256 indicativeQuote)
    {
        // ---- explicit venue -------------------------------------------------
        if (o.venueId != bytes32(0)) {
            // `getAdapter` reverts with VenueNotRegistered for an unknown id, so
            // that error is not duplicated here. No quote is taken: the caller has
            // already chosen the venue, so a quote would cost an external call and
            // change nothing.
            return (o.venueId, venueRegistry.getAdapter(o.venueId), 0);
        }

        // ---- best execution: venueId == bytes32(0) --------------------------
        uint256 count = venueRegistry.venueCount();
        if (count == 0) revert NoVenueAvailable();
        if (count > MAX_VENUES_SCANNED) revert TooManyVenues(count, MAX_VENUES_SCANNED);

        // Iterated by index rather than via `allVenueIds()`: that helper copies the
        // whole set into memory before any limit could be applied, so its cost is
        // paid even for a registry too large to scan.
        for (uint256 i; i < count; ++i) {
            bytes32 candidateVenueId = venueRegistry.venueIdAt(i);
            address candidateAdapter = venueRegistry.getAdapter(candidateVenueId);

            try IVenueAdapter(candidateAdapter).quote(o.assetIn, o.assetOut, o.amountIn) returns (uint256 candidate) {
                // Strictly-greater also filters out zero quotes, since
                // `indicativeQuote` starts at zero. A venue that cannot price the
                // pair returns 0 or reverts, and either way is skipped rather
                // than being allowed to fail the whole order — one broken venue
                // must not take best execution down with it.
                if (candidate > indicativeQuote) {
                    resolvedVenueId = candidateVenueId;
                    adapter = candidateAdapter;
                    indicativeQuote = candidate;
                }
            } catch {
                // Skip this venue. A reverting quote is a venue that cannot serve
                // the pair, not a reason to abort routing.
            }
        }

        if (adapter == address(0)) revert NoVenueAvailable();
    }
}
