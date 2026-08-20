// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IRebasingEquityToken
/// @notice Interface for a rebasing tokenised-equity token whose canonical
///         accounting unit is SHARES, not token balances.
/// @dev THE CENTRAL RULE. Shares are the stored, canonical quantity. Every
///      token-denominated value on this interface — `balanceOf`, `totalSupply`,
///      `transfer`, `allowance` — is a DERIVED VIEW computed as
///      `shares * multiplier / 1e18`.
///
///      A corporate action moves the global multiplier and therefore moves every
///      derived balance at once. It never moves share ownership.
///
///      UNIT DISCIPLINE — read this before integrating:
///        - `mint`, `redeem`, `transferShares`, `transferSharesFrom` take SHARE
///          amounts. They are exact.
///        - `transfer`, `transferFrom`, `approve` take TOKEN amounts. They pass
///          through an integer division and so may round.
///      Mixing the two up is the single easiest way to misuse this token, which
///      is why the share-denominated entry points are named distinctly rather
///      than overloaded.
interface IRebasingEquityToken is IERC20Metadata {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Zero amount supplied where a non-zero amount is required.
    error ZeroAmount();

    /// @notice Account holds fewer shares than the operation requires.
    error InsufficientShares(uint256 requested, uint256 available);

    /// @notice Spender has less allowance than the operation requires.
    error InsufficientAllowance(uint256 requested, uint256 available);

    /// @notice Proposed multiplier is zero, which would make every balance zero
    ///         and every token-to-share conversion a division by zero.
    error InvalidMultiplier();

    /// @notice Proposed multiplier is not strictly greater than the current one.
    ///         This token implements an UP-ONLY rebase policy.
    error MultiplierNotIncreasing(uint256 current, uint256 proposed);

    /// @notice A token-denominated transfer resolved to zero shares. Rejected
    ///         rather than silently succeeding while moving nothing.
    error TransferRoundsToZeroShares(uint256 tokenAmount, uint256 multiplier);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted alongside the ERC-20 `Transfer` on primary issuance.
    /// @param to          Recipient of the newly issued shares.
    /// @param shareAmount Shares created — the exact, canonical quantity.
    /// @param multiplier  Multiplier in force at issuance.
    /// @param tokenAmount Derived token value of `shareAmount` at `multiplier`.
    event SharesMinted(address indexed to, uint256 shareAmount, uint256 multiplier, uint256 tokenAmount);

    /// @notice Emitted alongside the ERC-20 `Transfer` on primary redemption.
    /// @param account     Account whose shares were destroyed.
    /// @param shareAmount Shares destroyed — the exact, canonical quantity.
    /// @param multiplier  Multiplier in force at redemption.
    /// @param tokenAmount Derived token value of `shareAmount` at `multiplier`.
    event SharesRedeemed(address indexed account, uint256 shareAmount, uint256 multiplier, uint256 tokenAmount);

    /// @notice Emitted when a corporate action moves the global multiplier.
    /// @dev `totalShares` is included precisely because it must be UNCHANGED by
    ///      the action; emitting it makes that auditable from the log alone.
    ///      No timestamp is included — the transaction already carries block
    ///      metadata, so restating it would be duplicate information.
    event CorporateActionApplied(uint256 oldMultiplier, uint256 newMultiplier, uint256 totalShares);

    /*//////////////////////////////////////////////////////////////
                          SHARE ACCOUNTING VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares owned by `account`. This is the canonical, stored quantity.
    /// @dev Unaffected by corporate actions.
    function shares(address account) external view returns (uint256);

    /// @notice Total shares in issue. Sum of `shares` over all holders.
    /// @dev Not part of the required assessment interface. Included because it
    ///      makes share conservation directly observable — invariant tests,
    ///      reconciliation against the share registry, and debugging all need it.
    function totalShares() external view returns (uint256);

    /// @notice Current global multiplier, scaled by 1e18.
    function multiplier() external view returns (uint256);

    /// @notice Token value of `shareAmount` at the current multiplier, floored.
    /// @dev Exposed so an integrator can compute exactly what a share quantity is
    ///      worth before moving it, rather than inferring it from balance reads.
    function sharesToAmount(uint256 shareAmount) external view returns (uint256);

    /// @notice Token value of `shareAmount` at the current multiplier, rounded UP.
    /// @dev The allowance-side conversion. {transferSharesFrom} debits exactly
    ///      this, so a caller that wants to grant permission over `shareAmount`
    ///      shares must approve at least this many tokens — approving
    ///      {sharesToAmount} instead can be one wei short and fail.
    ///
    ///      Rounds up, so it is NOT the inverse of {amountToShares}; it is the
    ///      right inverse. `amountToShares(sharesToAmountCeil(s)) == s` holds for
    ///      every `s` while the multiplier is at least `MULTIPLIER_SCALE`, which
    ///      is the lossless round trip {approveShares} relies on.
    function sharesToAmountCeil(uint256 shareAmount) external view returns (uint256);

    /// @notice Shares that `tokenAmount` resolves to at the current multiplier,
    ///         floored — i.e. exactly what {transfer} would move.
    /// @dev Pair with {sharesToAmount} to learn the shortfall before transferring:
    ///      `sharesToAmount(amountToShares(x)) <= x`.
    function amountToShares(uint256 tokenAmount) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            PRIMARY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice Issue `shareAmount` shares to `to`, backed 1:1 by the registry.
    /// @dev Takes a SHARE amount, not a token amount.
    /// @param to          Recipient.
    /// @param shareAmount Shares to issue.
    function mint(address to, uint256 shareAmount) external;

    /// @notice Destroy `shareAmount` of the caller's shares and release backing.
    /// @dev Takes a SHARE amount, not a token amount. Operates on msg.sender
    ///      only — there is no `redeemFrom`, so redemption cannot be initiated
    ///      on someone else's behalf.
    /// @param shareAmount Shares to redeem.
    function redeem(uint256 shareAmount) external;

    /*//////////////////////////////////////////////////////////////
                            CORPORATE ACTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Move the global multiplier to `newMultiplier`.
    /// @dev Must not touch share ownership. UP-ONLY: `newMultiplier` must be
    ///      strictly greater than the current multiplier.
    /// @param newMultiplier New multiplier, scaled by 1e18.
    function applyCorporateAction(uint256 newMultiplier) external;

    /*//////////////////////////////////////////////////////////////
                        SHARE-EXACT TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Move exactly `shareAmount` shares from the caller to `to`.
    /// @dev Extension beyond the required interface. Exists so share-denominated
    ///      settlement can move an exact share quantity without a round trip
    ///      through a rebasing token amount.
    function transferShares(address to, uint256 shareAmount) external returns (bool);

    /// @notice Move exactly `shareAmount` shares from `from` to `to`, spending
    ///         the caller's allowance.
    /// @dev The allowance is token-denominated (see {allowance}), so the debit is
    ///      the token value of `shareAmount`, ROUNDED UP. Rounding up means a
    ///      spender can never move more value than was approved.
    function transferSharesFrom(address from, address to, uint256 shareAmount) external returns (bool);

    /*//////////////////////////////////////////////////////////////
                    SHARE-DENOMINATED ALLOWANCE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Grant `spender` permission over exactly `shareAmount` shares of the
    ///         caller's, measured at the CURRENT multiplier.
    /// @dev Extension beyond the required interface, and a THIN DERIVED WRAPPER:
    ///      there is one allowance mapping and it is token-denominated (see
    ///      {allowance}). This is `approve(spender, sharesToAmountCeil(shareAmount))`
    ///      and nothing more — it does not introduce a second, share-denominated
    ///      allowance that could disagree with the token-denominated one.
    ///
    ///      REPLACES the allowance, it does not increment it, matching {approve}.
    ///
    ///      The share permission this grants is not fixed: because the stored
    ///      allowance is token-denominated while the multiplier only rises, the
    ///      share quantity it buys NEVER GROWS and decays as corporate actions
    ///      accrue. Read back with {allowanceShares}. That decay is the deliberate
    ///      fail-safe direction argued for in {allowance}; a caller relying on a
    ///      standing share permission must refresh it.
    /// @param spender     Party being granted permission.
    /// @param shareAmount Shares to grant permission over, at the current multiplier.
    function approveShares(address spender, uint256 shareAmount) external returns (bool);

    /// @notice `spender`'s outstanding allowance from `owner`, expressed in SHARES
    ///         at the current multiplier.
    /// @dev The authoritative read for "how many shares can this spender still
    ///      move": `allowanceShares(o, s) >= n` holds exactly when
    ///      `transferSharesFrom(o, _, n)` would pass the allowance check, because
    ///      both sides use the same ceil-then-floor conversion pair. The view and
    ///      the spend agree by construction rather than by coincidence.
    ///
    ///      Equals `amountToShares(allowance(owner, spender))`, so it inherits the
    ///      unlimited-allowance convention: a token allowance of `type(uint256).max`
    ///      is never decremented, and this reports the share value of that maximum
    ///      rather than a distinguishable "unlimited" sentinel.
    function allowanceShares(address owner, address spender) external view returns (uint256);
}
