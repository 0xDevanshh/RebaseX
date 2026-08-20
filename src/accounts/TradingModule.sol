// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Router} from "../core/Router.sol";
import {IRebasingEquityToken} from "../interfaces/IRebasingEquityToken.sol";
import {ISafe} from "../interfaces/ISafe.sol";
import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title TradingModule
/// @notice A Safe module holding trade-only authority over one client Safe.
///
/// @dev THE PERMISSION MODEL IS AN ALLOWLIST, NOT A DENYLIST.
///
///      THE OPERATOR MAY CAUSE EXACTLY TWO SAFE ACTIONS:
///        1. Submit an order to the Router whose `account` field is the Safe.
///        2. Set the Safe's share allowance to an owner-approved SettlementEngine,
///           within an owner-set cap.
///      There is no third. This module contains no function that can move assets
///      to an arbitrary address, for anyone, including the Safe owner — owner
///      withdrawal happens through the Safe directly and does not involve this
///      module at all.
///
///      A denylist would be the wrong framing. "Everything except withdraw" grants
///      by default, so the next dangerous action nobody thought of is permitted
///      before anyone notices it exists. An allowlist grants by enumeration: a
///      capability the ABI does not name cannot be reached, and adding one is a
///      visible diff to this file rather than an oversight.
///
///      ---
///
///      THE CENTRAL INSIGHT: BLOCKING WITHDRAWAL IS NOT SUFFICIENT.
///
///      An account that merely lacks a withdraw function is not non-custodial with
///      respect to its operator. If the operator can cause the Safe to approve an
///      arbitrary spender, the operator approves ITSELF and drains the Safe with
///      `transferFrom`. APPROVAL IS WITHDRAWAL, ONE INDIRECTION REMOVED. The
///      share-denominated path is no different: `approveShares` to an attacker
///      followed by `transferSharesFrom` is the same theft in share units.
///
///      This is why action 2 is bounded on BOTH ends rather than being a general
///      approval capability:
///        - the SPENDER must be an engine the owner allowlisted, and
///        - the RESULTING ALLOWANCE must sit within a cap the owner set.
///      An operator holding action 2 gains no capability the owner did not already
///      grant; it can only refresh a permission that already exists, inside a bound
///      the owner chose. See {setEngineShareAllowance} for the full argument and
///      for the residual risk that survives it.
///
///      ---
///
///      WHAT THIS MODULE DELIBERATELY CANNOT DO. Named first, because a reviewer
///      hunting for the withdrawal hole is going to look for exactly these, and
///      stating them is stronger than making them search:
///
///      - NO GENERIC `execute` OR ARBITRARY-CALL PASSTHROUGH. This is the single
///        most important omission. A passthrough would make every bound above
///        unenforceable by construction: the operator restriction would then rest
///        on inspecting calldata at runtime — parsing selectors, decoding
///        arguments, guessing at a token's ABI — rather than on the shape of this
///        contract's ABI. Bounds you can only enforce by reading calldata are
///        bounds you cannot audit. There is no `execute`, no `multicall`, no
///        "call the Safe with this blob".
///      - NO WITHDRAWAL FUNCTION OF ANY KIND, for anyone, owner included. Not
///        gated, not timelocked, not owner-only: absent. Owner withdrawal is a
///        normal Safe transaction that never touches this module.
///      - NO `Operation.DelegateCall`, anywhere. Every Safe execution here is
///        `Operation.Call`. A delegatecall from a module runs in the SAFE's storage
///        context and can rewrite the Safe's owners and modules — it is a total
///        compromise of the account, not a scoped action. Hard rule, enforced in
///        one place: {_execOnSafe}.
///      - NO UPGRADEABILITY, proxy, or initializer beyond the constructor. `safe`
///        and `router` are immutable. There is no admin who can repoint this module
///        at a different Router after the client has read this file.
///      - NO OPERATOR-SETTABLE STATE other than the bounded allowance of action 2.
///        Operators cannot add operators, allowlist engines, or raise caps.
///      - NO FALLBACK OR RECEIVE FUNCTION. The module holds no assets and has no
///        unreachable-by-ABI entry point.
///
///      ---
///
///      CLIENT EXIT REQUIRES NOTHING FROM THIS MODULE. The Safe owner calls
///      `disableModule(this)` on the Safe directly; the operator's authority ends
///      in that transaction. Withdrawal afterwards is an ordinary Safe owner
///      transaction. Neither step needs this module's cooperation, an operator's
///      signature, a timelock, or a cancellation window — so a client can always
///      leave ahead of a privileged change taking effect. This is stronger than
///      the equivalent argument for a bespoke account, because the exit primitive
///      is Safe's and not code we wrote: the client does not have to trust our
///      implementation of their escape hatch.
contract TradingModule {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the Safe. Owner-level configuration requires a Safe
    ///         owner transaction.
    error NotSafe();

    /// @notice Caller is neither the Safe nor an enabled operator.
    error NotAuthorized();

    /// @notice Order's `account` field is not this module's Safe.
    error OrderAccountMismatch(address account, address expected);

    /// @notice Engine is not on the owner's allowlist.
    error EngineNotApproved(address engine);

    /// @notice Resulting share allowance exceeds the owner's cap for this pair.
    error ExceedsShareCap(address engine, address token, uint256 resulting, uint256 cap);

    /// @notice Engine address is zero or has no code.
    error InvalidEngine(address engine);

    /// @notice Engine's approved-token set is already at {MAX_TOKENS_PER_ENGINE}.
    error TooManyTokensForEngine(address engine, uint256 maximum);

    /// @notice The Safe reported the module execution as failed.
    error ModuleExecutionFailed(address to, bytes returnData);

    /// @notice A required address argument was zero.
    error ZeroAddress();

    /// @notice A constructor argument that must be a contract has no code.
    /// @dev Not in the same family as {InvalidEngine}: this one is unrecoverable,
    ///      since both wiring addresses are immutable.
    error NotAContract(address account);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice An operator was granted or revoked trade authority.
    event OperatorSet(address operator, bool enabled);

    /// @notice A settlement engine was added to or removed from the allowlist.
    event ApprovedEngineSet(address engine, bool approved);

    /// @notice The Safe's token-denominated allowance to `engine` was set.
    event EngineTokenAllowanceSet(address engine, address token, uint256 amount);

    /// @notice The Safe's share-denominated allowance to `engine` was set.
    event EngineShareAllowanceSet(address engine, address token, uint256 shareAmount);

    /// @notice The owner's cap on `engine`'s share allowance for `token` was set.
    event EngineShareCapSet(address engine, address token, uint256 shareCap);

    /// @notice Every allowance the Safe held out to `engine` for `token` was zeroed.
    event EngineAllowanceRevoked(address engine, address token);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Most tokens one engine may hold allowances over simultaneously.
    /// @dev A LIVENESS BOUND, NOT A GAS OPTIMISATION. See {setApprovedEngine}.
    uint256 public constant MAX_TOKENS_PER_ENGINE = 8;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The client Safe this module acts for. Immutable, and the only Safe
    ///         this module can ever touch.
    address public immutable safe;

    /// @notice The Router orders are submitted to. Immutable.
    address public immutable router;

    /// @dev Operators authorised to exercise the two actions. Owner-set only.
    mapping(address operator => bool) private _operators;

    /// @dev Settlement engines the owner is willing to have hold allowances.
    mapping(address engine => bool) private _approvedEngines;

    /// @dev Per-pair ceiling on the share allowance an engine may end up holding.
    ///      THE REAL EXPOSURE BOUND — see {setEngineShareAllowance}.
    mapping(address engine => mapping(address token => uint256)) private _engineShareCap;

    /// @dev Tokens each engine currently holds an allowance over, so revocation has
    ///      something definite to iterate. Bounded by {MAX_TOKENS_PER_ENGINE}.
    mapping(address engine => EnumerableSet.AddressSet) private _approvedTokens;

    /// @dev Whether this module has granted a SHARE allowance for this pair.
    ///
    ///      Not in the original storage sketch; added because revocation needs to
    ///      know whether to also zero the share allowance, and every other way of
    ///      deciding puts an untrusted party in the emergency path:
    ///
    ///        - Asking the ENGINE (`isRebasingToken`) means a compromised engine can
    ///          revert the probe and make itself un-revocable. The engine is the
    ///          adversary in this scenario; it does not get a vote on whether it can
    ///          be switched off.
    ///        - Probing the TOKEN (`multiplier()`) is better but still lets a
    ///          non-conforming token answer one way and revert on `approveShares`,
    ///          bricking revocation for every other token in the same loop.
    ///
    ///      The module's own record of what it granted cannot lie and cannot revert.
    ///      If this flag is set, `approveShares` demonstrably exists on that token,
    ///      because this module already called it successfully.
    mapping(address engine => mapping(address token => bool)) private _shareApprovalGranted;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param safe_   Client Safe this module acts for.
    /// @param router_ Router orders are submitted to.
    constructor(address safe_, address router_) {
        if (safe_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (safe_.code.length == 0) revert NotAContract(safe_);
        if (router_.code.length == 0) revert NotAContract(router_);

        safe = safe_;
        router = router_;
    }

    /*//////////////////////////////////////////////////////////////
                              AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Owner-level gate. `msg.sender == safe` means the call arrived as a Safe
    ///      transaction the Safe sent to this module, which the Safe only does after
    ///      collecting `threshold` owner signatures.
    ///
    ///      WHY THIS IS STRONGER THAN STORING AN OWNER ADDRESS HERE. An `owner`
    ///      field would be a SECOND copy of an authority the Safe already defines,
    ///      and two copies of the same fact drift. Rotate a Safe owner, add one,
    ///      raise the threshold from 1-of-1 to 2-of-3 — none of that would reach a
    ///      local `owner`, so the module would keep honouring whoever it was
    ///      configured with while the client believes their new governance applies.
    ///      Gating on the Safe itself means the module's notion of "owner" is the
    ///      Safe's owner set and threshold, live, with no synchronisation step that
    ///      can be forgotten and no second access-control surface to audit.
    modifier onlySafe() {
        if (msg.sender != safe) revert NotSafe();
        _;
    }

    /// @dev Operator gate. The Safe is included so an owner can always perform any
    ///      operator action directly, without first appointing itself an operator.
    modifier onlyOperatorOrSafe() {
        if (msg.sender != safe && !_operators[msg.sender]) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether `op` may exercise the two operator actions.
    /// @dev NOT {IClientAccount.isOperator}, despite the matching name and shape.
    ///      This module is not the account — the Safe is — and the Router never
    ///      calls this. See {submitOrder} for why the Router does not need it.
    ///      Present for off-chain and owner inspection.
    function isOperator(address op) external view returns (bool) {
        return _operators[op];
    }

    /// @notice Whether `engine` is on the owner's allowlist.
    function isApprovedEngine(address engine) external view returns (bool) {
        return _approvedEngines[engine];
    }

    /// @notice Owner's ceiling on `engine`'s share allowance for `token`.
    /// @dev THE EXPOSURE BOUND A CLIENT SHOULD READ. The current allowance is a
    ///      snapshot an operator can refresh at will; this is the most the engine
    ///      can ever hold permission over.
    function engineShareCap(address engine, address token) external view returns (uint256) {
        return _engineShareCap[engine][token];
    }

    /// @notice Tokens `engine` currently holds an allowance over.
    /// @dev Bounded by {MAX_TOKENS_PER_ENGINE}, so returning the whole set is safe.
    ///      This is exactly the set {setApprovedEngine} iterates when revoking.
    function engineTokens(address engine) external view returns (address[] memory) {
        return _approvedTokens[engine].values();
    }

    /// @notice Whether this module has granted `engine` a share allowance for `token`.
    function hasShareApproval(address engine, address token) external view returns (bool) {
        return _shareApprovalGranted[engine][token];
    }

    /*//////////////////////////////////////////////////////////////
                       OWNER-GATED CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Grant or revoke `op`'s trade authority.
    /// @dev Revocation is immediate and unconditional: the operator has no standing
    ///      claim, no notice period, and nothing in flight that survives it.
    /// @param op      Operator address.
    /// @param enabled True to grant, false to revoke.
    function setOperator(address op, bool enabled) external onlySafe {
        if (op == address(0)) revert ZeroAddress();

        _operators[op] = enabled;

        emit OperatorSet(op, enabled);
    }

    /// @notice Set the owner's ceiling on `engine`'s share allowance for `token`.
    /// @dev Setting a cap does not grant an allowance; it bounds what
    ///      {setEngineShareAllowance} may leave in place. Lowering the cap does not
    ///      retroactively lower an allowance already granted — use
    ///      {revokeEngineAllowance} for that. Lowering it does prevent an operator
    ///      from refreshing back above the new value, which is what stops the
    ///      existing allowance from being renewed indefinitely.
    /// @param engine    Allowlisted engine.
    /// @param token     Token the cap applies to.
    /// @param shareCap  Maximum share allowance, in shares at read time.
    function setEngineShareCap(address engine, address token, uint256 shareCap) external onlySafe {
        if (!_approvedEngines[engine]) revert EngineNotApproved(engine);

        _engineShareCap[engine][token] = shareCap;

        emit EngineShareCapSet(engine, token, shareCap);
    }

    /// @notice Set the Safe's token-denominated allowance to `engine` for `token`.
    /// @dev OWNER-ONLY, deliberately. This is the general approval capability, and
    ///      it is exactly the capability an operator must not have — see the
    ///      contract-level note on approval being withdrawal. The operator's
    ///      counterpart, {setEngineShareAllowance}, is bounded by a cap; this one is
    ///      not, because the owner setting their own allowance IS the authority the
    ///      cap exists to represent.
    ///
    ///      Passing `amount == 0` zeroes the allowance but leaves `token` in the
    ///      engine's set. That is intentional rather than a missed cleanup: this
    ///      function's job is to set an amount, and the set records which pairs the
    ///      revocation loop must visit — an entry with a zero allowance costs one
    ///      redundant `approve(0)` there. {revokeEngineAllowance} is the function
    ///      that zeroes AND removes.
    /// @param engine Allowlisted engine.
    /// @param token  Token to approve.
    /// @param amount Token-denominated allowance.
    function setEngineTokenAllowance(address engine, address token, uint256 amount) external onlySafe {
        if (!_approvedEngines[engine]) revert EngineNotApproved(engine);

        _execOnSafe(token, abi.encodeCall(IERC20.approve, (engine, amount)));
        _trackToken(engine, token);

        emit EngineTokenAllowanceSet(engine, token, amount);
    }

    /// @notice Add `engine` to the allowlist, or remove it and revoke everything it
    ///         holds.
    ///
    /// @dev DEALLOWLISTING MUST ACTUALLY REVOKE. Removing an engine is the
    ///      EMERGENCY action — what the owner does at the moment they learn the
    ///      engine is compromised. If it only cleared a flag and left the standing
    ///      allowances intact, the emergency action would not stop the emergency:
    ///      the engine could still call `transferFrom` for the full outstanding
    ///      amount, and the owner would be looking at a `false` in storage while
    ///      their assets left. Clearing the flag only prevents FUTURE allowances,
    ///      and future allowances are not the problem.
    ///
    ///      ORDERING IS LOAD-BEARING: revoke while the engine is STILL allowlisted,
    ///      then clear the flag. The revocation path shares {_revokeAllowances} with
    ///      {revokeEngineAllowance}, which deliberately does not require the engine
    ///      to be approved — but if it did, and this function cleared the flag
    ///      first, the owner would have locked themselves out of revoking by the
    ///      very act of deallowlisting. Written in this order, and tested in this
    ///      order.
    ///
    ///      REVOCATION MUST NOT BE SILENTLY PARTIAL. The loop body is NOT wrapped in
    ///      try/catch, and that is a deliberate choice with a named failure mode. If
    ///      one `approve(engine, 0)` reverts — a token that rejects zero approvals,
    ///      a token that reverts on a blocklisted holder — the entire call reverts
    ///      and nothing changes. The alternative is worse than a revert: some
    ///      allowances zeroed, some still live, and the engine marked deallowlisted,
    ///      so the owner believes capability is revoked while it is not. A failed
    ///      emergency action must look failed. The cost is that one unzeroable token
    ///      blocks bulk deallowlisting for that engine; {revokeEngineAllowance} is
    ///      the answer, letting the owner clear the pairs that can be cleared and
    ///      then deallowlist against a smaller set.
    ///
    ///      WHY THE TOKEN SET IS BOUNDED — a liveness fix, not a gas optimisation.
    ///      This loop is the emergency path, so it must always be executable. An
    ///      unbounded set would mean anyone who can cause tokens to be approved to
    ///      an engine can grow that set until the loop exceeds the block gas limit,
    ///      making the engine PERMANENTLY UN-REVOCABLE — a liveness failure located
    ///      in precisely the call that can never be allowed to fail. Bounding the
    ///      set at {MAX_TOKENS_PER_ENGINE} removes the attack: the loop's worst case
    ///      is a constant this contract fixes. Eight is generous against any
    ///      realistic number of assets one engine settles.
    ///
    /// @param engine   Engine to allowlist or remove.
    /// @param approved True to allowlist, false to remove and revoke.
    function setApprovedEngine(address engine, bool approved) external onlySafe {
        if (approved) {
            if (engine == address(0) || engine.code.length == 0) revert InvalidEngine(engine);
        } else {
            // Snapshot before mutating. `values()` copies, so the loop is iterating
            // memory and `clear()` afterwards cannot disturb it.
            address[] memory tokens = _approvedTokens[engine].values();

            for (uint256 i; i < tokens.length; ++i) {
                _revokeAllowances(engine, tokens[i]);
            }

            _approvedTokens[engine].clear();
        }

        _approvedEngines[engine] = approved;

        emit ApprovedEngineSet(engine, approved);
    }

    /// @notice Zero every allowance the Safe holds out to `engine` for one `token`.
    ///
    /// @dev THE PER-TOKEN ESCAPE HATCH, and the second half of a deliberate pair.
    ///      {setApprovedEngine} gives a bulk revocation whose cost is bounded by
    ///      {MAX_TOKENS_PER_ENGINE}; this gives a constant-gas revocation that does
    ///      not touch the set as a whole and works regardless of allowlist state.
    ///
    ///      Having only one would leave the emergency path dependent on a structure
    ///      the owner does not fully control — the set's contents are a function of
    ///      past configuration, not of the owner's present intent. With both, even
    ///      if the bulk path were somehow unexecutable, the owner can revoke pair by
    ///      pair and then deallowlist against an empty set.
    ///
    ///      DOES NOT REQUIRE THE ENGINE TO BE APPROVED. An allowance can outlive an
    ///      allowlist entry — that is the exact state {setApprovedEngine}'s ordering
    ///      note warns about — and refusing to revoke in that state would make this
    ///      useless precisely when it is needed.
    ///
    ///      Removes `token` from the engine's set. That removal is not bookkeeping
    ///      hygiene: without it the set only ever grows, and an engine would reach
    ///      {MAX_TOKENS_PER_ENGINE} through churn — the same pair approved, revoked,
    ///      and approved again — rather than through real breadth of assets.
    /// @param engine Engine whose permission is being withdrawn.
    /// @param token  Token to revoke.
    function revokeEngineAllowance(address engine, address token) external onlySafe {
        _revokeAllowances(engine, token);
        _approvedTokens[engine].remove(token);
    }

    /*//////////////////////////////////////////////////////////////
                    OPERATOR ACTION 1 — SUBMIT ORDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit `o` to the Router, executed by the Safe.
    ///
    /// @dev HOW ROUTER AUTHORIZATION IS ESTABLISHED — worth stating precisely,
    ///      because it is easy to describe wrongly.
    ///
    ///      The Router authorizes on:
    ///          msg.sender == o.account || IClientAccount(o.account).isOperator(msg.sender)
    ///
    ///      Through this module, the call chain is
    ///          operator -> TradingModule -> Safe -> Router
    ///      because the module calls `execTransactionFromModuleReturnData` and the
    ///      SAFE performs the outbound call. So the Router sees `msg.sender == safe`
    ///      and `o.account == safe`, and THE FIRST BRANCH PASSES. `isOperator` is
    ///      never reached, and the Safe never needs to implement it.
    ///
    ///      THE DISTINCTION: authorization is established by THE SAFE BEING THE
    ///      CALLER — not by the Safe attesting to who its operators are. Nothing
    ///      downstream of this module knows an operator was involved, or asks.
    ///      Operator authorization lives entirely HERE, in {onlyOperatorOrSafe} and
    ///      the `o.account` check below, upstream of the Router. THIS MODULE IS THE
    ///      TRUST BOUNDARY; the Router simply sees a self-submitted order and has no
    ///      opinion about how the Safe decided to send it.
    ///
    ///      CONSEQUENCE FOR {IClientAccount}. It is a ROUTER-SIDE interface that
    ///      only bespoke, non-Safe accounts would implement. A Safe-based account
    ///      never implements it, and this module implementing an `isOperator` view
    ///      does not change that — the module is not the account. A direct
    ///      operator -> Router call naming the Safe as `o.account` therefore REVERTS
    ///      with `UnauthorizedCaller`: `msg.sender != o.account`, and the Safe has
    ///      no `isOperator`, so the Router's try/catch fails closed. That path is
    ///      unsupported for Safe-based accounts BY DESIGN, and every order must come
    ///      through this module. Production would install a
    ///      `CompatibilityFallbackHandler` extension on the Safe to answer
    ///      `isOperator` and support the direct path; cut here for scope.
    ///
    ///      WHY `o.account == safe` IS ESSENTIAL. Without it an operator could pass
    ///      an order naming a DIFFERENT account and have the Safe submit it, using
    ///      this module purely as an authorization shim. The Router would authorize
    ///      on the Safe being the caller — but the Safe is not `o.account`, so the
    ///      first branch fails and it would fall through to
    ///      `IClientAccount(other).isOperator(safe)`. Any account that had ever
    ///      named this Safe an operator would then be drained on the operator's
    ///      instruction. This check is what confines the module to its own Safe.
    ///
    ///      WHY THE RETURN VALUE IS CHECKED. Safe's module execution returns a
    ///      `bool` rather than bubbling the inner revert. An unchecked call would
    ///      make every failed settlement look like a successful one that returned
    ///      zero — silently, with an `ExecutionFromModuleFailure` event nobody is
    ///      reading. {_execOnSafe} converts that into a revert.
    /// @param o Order to submit. `o.account` must be this module's Safe.
    /// @return amountOut Output amount reported by settlement.
    function submitOrder(OrderTypes.Order calldata o) external onlyOperatorOrSafe returns (uint256 amountOut) {
        if (o.account != safe) revert OrderAccountMismatch(o.account, safe);

        bytes memory returnData = _execOnSafe(router, abi.encodeCall(Router.submitOrder, (o)));

        return abi.decode(returnData, (uint256));
    }

    /*//////////////////////////////////////////////////////////////
              OPERATOR ACTION 2 — SET ENGINE SHARE ALLOWANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the Safe's SHARE allowance to `engine` for `token`.
    ///
    /// @dev NAMED `set`, NOT `topUp`. `approveShares` REPLACES the allowance rather
    ///      than incrementing it, and an operator may lower it as well as raise it.
    ///      "topUp" would promise monotonicity this function does not have, and a
    ///      caller who believed it would read a smaller argument as a smaller
    ///      increment rather than as a reduction.
    ///
    ///      ---
    ///
    ///      WHY THIS FUNCTION EXISTS. Allowances on the rebasing token are stored
    ///      TOKEN-DENOMINATED. `approveShares(S)` stores `A = ceil(S * m0 / 1e18)`,
    ///      and `allowanceShares` reads back `floor(A * 1e18 / m)`. So a share
    ///      permission granted once does not stay worth `S` shares as the multiplier
    ///      rises, and something has to be able to refresh it.
    ///
    ///      AT `m0` THE READBACK IS EXACTLY `S`, by the lossless round trip
    ///      `amountToShares(sharesToAmountCeil(S)) == S`, which holds for every `S`
    ///      while `m >= 1e18`.
    ///
    ///      AFTER AN UP-ONLY REBASE TO `m1 > m0` THE SHARE SPENDING POWER NEVER
    ///      INCREASES. `A * 1e18 / m` is decreasing in `m` and `floor` is monotone,
    ///      so `allowanceShares <= S` always. This is the fail-safe direction, and
    ///      it is the property the design actually relies on.
    ///
    ///      IT DOES NOT ALWAYS STRICTLY DECREASE. Integer rounding can leave it
    ///      exactly equal to `S` across a small multiplier increase, because the
    ///      ceil at approval time leaves up to one wei of headroom. Concretely:
    ///      `m0 = 1e18 + 1`, `S = 1` gives `A = 2`, and at `m1 = 1e18 + 2` the
    ///      readback is still `1`.
    ///
    ///      THE THRESHOLD IS EXACT: `allowanceShares < S` iff `m1 > A * 1e18 / S`.
    ///      Since `A < S * m0 / 1e18 + 1`, the window in which `S` still fits is
    ///      narrower than `1e18 / S` in multiplier units, so it collapses quickly as
    ///      `S` grows. Note also that from exact parity (`m0 == 1e18`) there is no
    ///      ceil headroom at all — `A == S` — so any increase shrinks the readback
    ///      immediately. The equal-across-a-rebase case requires a non-parity
    ///      starting multiplier.
    ///
    ///      THE VIEW AND THE SPEND AGREE. `transferSharesFrom(S)` debits
    ///      `ceil(S * m1 / 1e18)`, which fits within `A` under exactly the same
    ///      condition `m1 <= A * 1e18 / S`. So "allowanceShares >= S" and "the spend
    ///      succeeds" are EQUIVALENT, not merely correlated — a caller can trust the
    ///      view as a decision procedure rather than as an estimate.
    ///
    ///      To be precise about what is NOT claimed: the allowance never grows, may
    ///      remain equal under a small increase, and falls below `S` once the
    ///      increase passes the threshold above. It is not true that it strictly
    ///      shrinks after any corporate action, and the fail-safe argument does not
    ///      need that.
    ///
    ///      ---
    ///
    ///      SCOPE NOTE, so this does not read as redundant with A4's rounding proof.
    ///      The `SettlementEngine` RECOMPUTES `sharesIn` from `o.amountIn` at the
    ///      SETTLEMENT-TIME multiplier, so its allowance fits by construction,
    ///      multiplier-independently. Here `S` is FIXED AT APPROVAL TIME and consumed
    ///      later at a different multiplier, so that proof does not apply. Two
    ///      different quantities that happen to share a symbol.
    ///
    ///      ---
    ///
    ///      WHY THIS DOES NOT BREAK THE PERMISSION MODEL. The danger of an
    ///      operator-callable approval is that the operator approves ITSELF, or a
    ///      third party, and drains. This cannot: the spender is constrained to an
    ///      engine the OWNER allowlisted, and the resulting allowance is constrained
    ///      to a cap the OWNER set. The operator gains no capability the owner did
    ///      not already grant — it can only refresh a permission that already
    ///      exists, within a bound the owner chose.
    ///
    ///      RESIDUAL RISK, PLAINLY. A compromised operator can hold the allowance at
    ///      the cap indefinitely, refreshing it after every corporate action. So THE
    ///      CAP IS THE REAL EXPOSURE BOUND, not the current allowance. A client
    ///      sizing a cap should read it as "the most this engine can ever hold
    ///      permission over", never as "the amount I am approving now".
    ///
    ///      REJECTED ALTERNATIVES:
    ///        - INFINITE APPROVAL TO THE ENGINE. Multiplier-immune and needs no
    ///          refresh, which is genuinely simpler. Rejected because it exposes the
    ///          Safe's entire balance — present and future — to a compromised engine
    ///          with no bound at all. The cap exists precisely to avoid this.
    ///        - OWNER-ONLY APPROVAL WITH GENEROUS HEADROOM. Works until the headroom
    ///          is consumed, then reintroduces the same liveness failure: trading
    ///          halts until an owner transaction lands, and it halts at an
    ///          unpredictable moment determined by rebase history rather than by
    ///          anything the owner scheduled.
    ///
    /// @param engine      Allowlisted engine to approve.
    /// @param token       Rebasing token to approve shares of.
    /// @param shareAmount Shares to grant permission over, at the current multiplier.
    function setEngineShareAllowance(address engine, address token, uint256 shareAmount) external onlyOperatorOrSafe {
        if (!_approvedEngines[engine]) revert EngineNotApproved(engine);

        _execOnSafe(token, abi.encodeCall(IRebasingEquityToken.approveShares, (engine, shareAmount)));

        // CHECK THE RESULTING STATE, NOT THE ARGUMENT. One check, positioned where
        // it is authoritative.
        //
        // There is deliberately no argument-side pre-check on `shareAmount`. With
        // `approveShares` the two are equivalent today — the readback at the
        // approval multiplier is exactly the argument — so a pre-check would add no
        // safety, only a SECOND PLACE THE BOUND IS EXPRESSED. And the two places
        // would not stay equivalent: if the primitive were ever switched to an
        // incrementing one, or gained a fee, or clamped, the argument-side reasoning
        // would silently stop bounding anything while still looking like a bound.
        // Checking the state the engine can actually spend against cannot come
        // apart from what it bounds.
        //
        // The transaction is atomic, so an over-cap approval is never observable and
        // never persists: the approval and this revert are the same transaction.
        uint256 resulting = IRebasingEquityToken(token).allowanceShares(safe, engine);
        uint256 cap = _engineShareCap[engine][token];
        if (resulting > cap) revert ExceedsShareCap(engine, token, resulting, cap);

        _trackToken(engine, token);
        _shareApprovalGranted[engine][token] = true;

        emit EngineShareAllowanceSet(engine, token, shareAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: SAFE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev THE ONLY PLACE THIS MODULE CAUSES THE SAFE TO ACT. Every outbound
    ///      capability in this contract funnels through here, which is what makes
    ///      the two hard rules auditable in one place rather than at each call site:
    ///
    ///        1. `Operation.Call`, ALWAYS. Never `DelegateCall`. A delegatecall from
    ///           a module executes the target's code in the SAFE's storage context
    ///           and can rewrite the Safe's owner set and module list — it is not a
    ///           scoped action but total control of the account. `Operation.Call` is
    ///           hardcoded here and the parameter is not exposed to any caller, so
    ///           no code path in this module can reach a delegatecall.
    ///        2. `success` IS CHECKED. Safe returns a bool for module execution
    ///           instead of bubbling the inner revert, so an unchecked call silently
    ///           converts failure into success-returning-nothing.
    ///
    ///      `value` is hardcoded to zero: the module has no reason to move the
    ///      Safe's native balance, and not exposing it means it cannot.
    ///
    ///      The inner revert data is returned in the error so a failure remains
    ///      diagnosable — a settlement that failed on slippage should not surface as
    ///      an opaque `ModuleExecutionFailed`.
    function _execOnSafe(address to, bytes memory data) private returns (bytes memory) {
        (bool success, bytes memory returnData) =
            ISafe(safe).execTransactionFromModuleReturnData(to, 0, data, ISafe.Operation.Call);

        if (!success) revert ModuleExecutionFailed(to, returnData);

        return returnData;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: TOKEN SET & REVOCATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Record that `engine` holds an allowance over `token`, enforcing the
    ///      bound that keeps {setApprovedEngine}'s revocation loop executable.
    ///      Idempotent — re-approving an already-tracked pair is not a new entry and
    ///      cannot push a full set over the limit.
    function _trackToken(address engine, address token) private {
        EnumerableSet.AddressSet storage tokens = _approvedTokens[engine];

        if (!tokens.contains(token) && tokens.length() >= MAX_TOKENS_PER_ENGINE) {
            revert TooManyTokensForEngine(engine, MAX_TOKENS_PER_ENGINE);
        }

        tokens.add(token);
    }

    /// @dev Zero every allowance the Safe holds out to `engine` for `token`, and
    ///      the cap that permitted it. Does NOT touch `_approvedTokens`, so the bulk
    ///      path can iterate a snapshot and clear the set once at the end while the
    ///      per-token path removes a single entry.
    ///
    ///      NO try/catch, by design — see {setApprovedEngine}. A revert here reverts
    ///      the whole revocation rather than leaving a partially-revoked engine
    ///      marked as revoked.
    ///
    ///      The share allowance is zeroed only when this module granted one. That
    ///      call is belt-and-braces against a token implementation keeping a share
    ///      allowance SEPARATE from its ERC-20 allowance; in
    ///      {MockRebasingEquityToken} there is one mapping, so `approve(engine, 0)`
    ///      has already zeroed it and this second call is redundant but harmless.
    ///      Gating on the module's own record is what keeps the redundancy from
    ///      becoming a liability: `approveShares` is only called on a token that has
    ///      already accepted it. See {_shareApprovalGranted}.
    ///
    ///      The cap is cleared too. Leaving it would mean a re-allowlisted engine
    ///      inherits a ceiling the owner set under different assumptions, and an
    ///      operator could refresh straight back to it without the owner acting.
    function _revokeAllowances(address engine, address token) private {
        _execOnSafe(token, abi.encodeCall(IERC20.approve, (engine, 0)));

        if (_shareApprovalGranted[engine][token]) {
            _execOnSafe(token, abi.encodeCall(IRebasingEquityToken.approveShares, (engine, 0)));
            _shareApprovalGranted[engine][token] = false;
        }

        _engineShareCap[engine][token] = 0;

        emit EngineAllowanceRevoked(engine, token);
    }
}
