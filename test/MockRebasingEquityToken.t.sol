// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {IRebasingEquityToken} from "../src/interfaces/IRebasingEquityToken.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";

/*//////////////////////////////////////////////////////////////////////////
                        TEST HARNESS
//////////////////////////////////////////////////////////////////////////*/

/// @dev Exposes the internal conversion helpers so their rounding behaviour can
///      be fuzzed directly. Test-only; adds no surface to the deployed token.
contract RebasingTokenHarness is MockRebasingEquityToken {
    constructor(string memory n, string memory s, address admin, IShareRegistry r)
        MockRebasingEquityToken(n, s, admin, r)
    {}

    function toShares(uint256 tokenAmount) external view returns (uint256) {
        return _toShares(tokenAmount);
    }

    function toAmount(uint256 shareAmount) external view returns (uint256) {
        return _toAmount(shareAmount);
    }

    function toAmountCeil(uint256 shareAmount) external view returns (uint256) {
        return _toAmountCeil(shareAmount);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        SHARED FIXTURE
//////////////////////////////////////////////////////////////////////////*/

abstract contract RebasingTokenFixture is Test {
    RebasingTokenHarness internal token;
    MockShareRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal corpActor = makeAddr("corpActor");
    address internal stranger = makeAddr("stranger");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant ONE = 1e18;
    uint256 internal constant CUSTODIED = 1e27;

    /// @dev Hardcoded rather than read from the token: a getter call would be an
    ///      external call that consumes a pending `vm.prank`, and a test should
    ///      not assert a contract against its own getter.
    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal constant PRIMARY_ROLE = keccak256("PRIMARY_ROLE");
    bytes32 internal constant CORPORATE_ACTION_ROLE = keccak256("CORPORATE_ACTION_ROLE");

    function _deployAndWire() internal {
        registry = new MockShareRegistry(admin);
        token = new RebasingTokenHarness("Mock Equity", "mEQ", admin, IShareRegistry(address(registry)));

        vm.startPrank(admin);
        registry.registerToken(address(token));
        registry.setCustodiedShares(address(token), CUSTODIED);
        token.grantRole(PRIMARY_ROLE, minter);
        token.grantRole(CORPORATE_ACTION_ROLE, corpActor);
        vm.stopPrank();
    }

    function _mint(address to, uint256 shareAmount) internal {
        vm.prank(minter);
        token.mint(to, shareAmount);
    }

    function _rebase(uint256 newMultiplier) internal {
        vm.prank(corpActor);
        token.applyCorporateAction(newMultiplier);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        UNIT + FUZZ TESTS
//////////////////////////////////////////////////////////////////////////*/

contract MockRebasingEquityTokenTest is RebasingTokenFixture {
    function setUp() public {
        _deployAndWire();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_initialState() public view {
        assertEq(token.multiplier(), ONE, "multiplier");
        assertEq(token.totalShares(), 0, "totalShares");
        assertEq(token.totalSupply(), 0, "totalSupply");
        assertEq(token.decimals(), 18, "decimals");
        assertEq(token.name(), "Mock Equity");
        assertEq(token.symbol(), "mEQ");
        assertEq(address(token.registry()), address(registry));
        assertTrue(token.hasRole(ADMIN_ROLE, admin));
    }

    /// @dev Neither privileged role is granted to admin at construction.
    function test_initialState_rolesNotGrantedToAdmin() public view {
        assertFalse(token.hasRole(PRIMARY_ROLE, admin));
        assertFalse(token.hasRole(CORPORATE_ACTION_ROLE, admin));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(IRebasingEquityToken.ZeroAddress.selector);
        new MockRebasingEquityToken("n", "s", address(0), IShareRegistry(address(registry)));
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(IRebasingEquityToken.ZeroAddress.selector);
        new MockRebasingEquityToken("n", "s", admin, IShareRegistry(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_byPrimaryRole() public {
        _mint(alice, 100);

        assertEq(token.shares(alice), 100, "alice shares");
        assertEq(token.totalShares(), 100, "totalShares");
        assertEq(token.balanceOf(alice), 100, "alice balance at 1e18");
        assertEq(token.totalSupply(), 100, "totalSupply");
    }

    function test_mint_allocatesRegistryShares() public {
        _mint(alice, 100);

        assertEq(registry.allocatedShares(address(token)), 100, "registry allocated");
        assertEq(registry.availableShares(address(token)), CUSTODIED - 100, "registry available");
    }

    function test_mint_accumulatesAcrossHolders() public {
        _mint(alice, 100);
        _mint(bob, 250);

        assertEq(token.shares(alice), 100);
        assertEq(token.shares(bob), 250);
        assertEq(token.totalShares(), 350);
        assertEq(registry.allocatedShares(address(token)), 350);
    }

    function test_revert_mint_fromNonPrimaryRole() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, PRIMARY_ROLE)
        );
        token.mint(alice, 100);
    }

    /// @dev The corporate-action authority cannot mint. Role separation is the
    ///      point: neither privileged key subsumes the other.
    function test_revert_mint_fromCorporateActionRole() public {
        vm.prank(corpActor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, corpActor, PRIMARY_ROLE)
        );
        token.mint(alice, 100);
    }

    function test_revert_mint_toZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(IRebasingEquityToken.ZeroAddress.selector);
        token.mint(address(0), 100);
    }

    function test_revert_mint_zeroShares() public {
        vm.prank(minter);
        vm.expectRevert(IRebasingEquityToken.ZeroAmount.selector);
        token.mint(alice, 0);
    }

    /// @dev The registry is the binding constraint on issuance: the token cannot
    ///      mint more shares than the registry records as backed.
    function test_revert_mint_beyondRegistryBacking() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IShareRegistry.InsufficientAvailableShares.selector, CUSTODIED + 1, CUSTODIED)
        );
        token.mint(alice, CUSTODIED + 1);
    }

    function test_event_mint() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(address(0), alice, 100);
        vm.expectEmit(true, true, true, true, address(token));
        emit IRebasingEquityToken.SharesMinted(alice, 100, ONE, 100);

        vm.prank(minter);
        token.mint(alice, 100);
    }

    /*//////////////////////////////////////////////////////////////
                        BALANCE DERIVATION
    //////////////////////////////////////////////////////////////*/

    function test_balanceDerivation_atOne() public {
        _mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);
    }

    function test_balanceDerivation_atOnePointFive() public {
        _mint(alice, 100);
        _rebase(1.5e18);

        assertEq(token.shares(alice), 100, "shares must not move");
        assertEq(token.balanceOf(alice), 150, "100 * 1.5");
        assertEq(token.totalSupply(), 150);
    }

    function test_balanceDerivation_atTwo() public {
        _mint(alice, 100);
        _rebase(2e18);

        assertEq(token.shares(alice), 100, "shares must not move");
        assertEq(token.balanceOf(alice), 200, "100 * 2");
        assertEq(token.totalSupply(), 200);
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER (TOKEN AMOUNTS)
    //////////////////////////////////////////////////////////////*/

    function test_transfer_movesSharesAndBalances() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.transfer(bob, 400);

        assertEq(token.shares(alice), 600, "alice shares");
        assertEq(token.shares(bob), 400, "bob shares");
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
    }

    function test_transfer_doesNotChangeTotals() public {
        _mint(alice, 1000);
        uint256 sharesBefore = token.totalShares();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, 400);

        assertEq(token.totalShares(), sharesBefore, "totalShares changed");
        assertEq(token.totalSupply(), supplyBefore, "totalSupply changed");
        assertEq(registry.allocatedShares(address(token)), sharesBefore, "registry moved");
    }

    function test_transfer_afterRebase() public {
        _mint(alice, 1000);
        _rebase(2e18); // alice: 1000 shares, 2000 tokens

        vm.prank(alice);
        token.transfer(bob, 500); // 500 tokens == 250 shares

        assertEq(token.shares(alice), 750, "alice shares");
        assertEq(token.shares(bob), 250, "bob shares");
        assertEq(token.balanceOf(bob), 500, "bob balance");
        assertEq(token.totalShares(), 1000, "shares conserved");
    }

    function test_transfer_fullBalanceAfterCleanRebase() public {
        _mint(alice, 1000);
        _rebase(2e18);

        // Documented behaviour: a full-balance transfer works fine when the
        // multiplier divides the amount cleanly. It is NOT true that full
        // transfers always fail after a rebase.
        // NB: the balance is read BEFORE the prank -- an external call placed in
        // the argument list would consume the prank and redirect the transfer.
        uint256 full = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(bob, full);

        assertEq(token.shares(alice), 0);
        assertEq(token.shares(bob), 1000);
    }

    function test_revert_transfer_toZeroAddress() public {
        _mint(alice, 1000);
        vm.prank(alice);
        vm.expectRevert(IRebasingEquityToken.ZeroAddress.selector);
        token.transfer(address(0), 100);
    }

    function test_revert_transfer_insufficientShares() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.InsufficientShares.selector, 101, 100));
        token.transfer(bob, 101);
    }

    function test_revert_transfer_zeroAmount() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(IRebasingEquityToken.ZeroAmount.selector);
        token.transfer(bob, 0);
    }

    /// @dev A token amount too small to resolve to a single share is rejected
    ///      rather than silently succeeding while moving nothing.
    function test_revert_transfer_roundsToZeroShares() public {
        _mint(alice, 1000);
        _rebase(2e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.TransferRoundsToZeroShares.selector, 1, 2e18));
        token.transfer(bob, 1);
    }

    function test_event_transfer_reportsSharesActuallyMoved() public {
        _mint(alice, 1000);
        _rebase(3e18); // 1 share == 3 tokens

        // Requesting 7 tokens resolves to 2 shares (floor(7/3)), worth 6 tokens.
        // The event must report 6, the value actually moved -- not the 7 asked for.
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(alice, bob, 6);

        vm.prank(alice);
        token.transfer(bob, 7);

        assertEq(token.shares(bob), 2, "bob shares");
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER SHARES (EXACT)
    //////////////////////////////////////////////////////////////*/

    function test_transferShares_movesExactQuantity() public {
        _mint(alice, 1000);
        _rebase(3e18); // deliberately a multiplier that divides badly

        uint256 aliceBefore = token.shares(alice);
        uint256 bobBefore = token.shares(bob);

        vm.prank(alice);
        token.transferShares(bob, 333);

        assertEq(aliceBefore - token.shares(alice), 333, "sender debit");
        assertEq(token.shares(bob) - bobBefore, 333, "recipient credit");
        assertEq(token.totalShares(), 1000, "totalShares changed");
    }

    function test_transferShares_debitEqualsCreditExactly() public {
        _mint(alice, 1000);
        _rebase(1.333333333333333333e18);

        uint256 aliceBefore = token.shares(alice);
        uint256 bobBefore = token.shares(bob);

        vm.prank(alice);
        token.transferShares(bob, 777);

        assertEq(aliceBefore - token.shares(alice), token.shares(bob) - bobBefore, "debit != credit");
        assertEq(token.totalShares(), 1000);
    }

    function test_revert_transferShares_zeroAmount() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(IRebasingEquityToken.ZeroAmount.selector);
        token.transferShares(bob, 0);
    }

    function test_revert_transferShares_insufficientShares() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.InsufficientShares.selector, 101, 100));
        token.transferShares(bob, 101);
    }

    function test_revert_transferShares_toZeroAddress() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(IRebasingEquityToken.ZeroAddress.selector);
        token.transferShares(address(0), 10);
    }

    /*//////////////////////////////////////////////////////////////
                    APPROVE / ALLOWANCE / TRANSFER FROM
    //////////////////////////////////////////////////////////////*/

    function test_approve_setsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 500);
        assertEq(token.allowance(alice, bob), 500);
    }

    function test_event_approve() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(alice, bob, 500);

        vm.prank(alice);
        token.approve(bob, 500);
    }

    function test_revert_approve_zeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(IRebasingEquityToken.ZeroAddress.selector);
        token.approve(address(0), 500);
    }

    function test_transferFrom_spendsAllowanceAndMovesShares() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, 500);

        vm.prank(bob);
        token.transferFrom(alice, carol, 400);

        assertEq(token.shares(alice), 600);
        assertEq(token.shares(carol), 400);
        assertEq(token.allowance(alice, bob), 100, "allowance not decremented");
    }

    function test_revert_transferFrom_insufficientAllowance() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, 100);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.InsufficientAllowance.selector, 101, 100));
        token.transferFrom(alice, carol, 101);
    }

    /// @dev Max allowance is treated as unlimited and never decremented, the
    ///      conventional ERC-20 optimisation.
    function test_transferFrom_infiniteAllowanceNotDecremented() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 400);

        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite allowance decremented");
    }

    function test_transferSharesFrom_spendsAllowance() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, 500);

        vm.prank(bob);
        token.transferSharesFrom(alice, carol, 300);

        assertEq(token.shares(alice), 700);
        assertEq(token.shares(carol), 300);
        // At multiplier 1e18, 300 shares == 300 tokens.
        assertEq(token.allowance(alice, bob), 200);
    }

    /// @dev The allowance debit for a share-exact transfer rounds UP, so the
    ///      spender is never under-charged for the value moved.
    function test_transferSharesFrom_allowanceDebitRoundsUp() public {
        _mint(alice, 1000);
        _rebase(1.5e18);

        vm.prank(alice);
        token.approve(bob, 100);

        // 3 shares at 1.5x == 4.5 tokens, which must debit 5, not 4.
        vm.prank(bob);
        token.transferSharesFrom(alice, carol, 3);

        assertEq(token.shares(carol), 3, "exact shares moved");
        assertEq(token.allowance(alice, bob), 95, "debit should round up to 5");
    }

    function test_revert_transferSharesFrom_insufficientAllowance() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, 10);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.InsufficientAllowance.selector, 11, 10));
        token.transferSharesFrom(alice, carol, 11);
    }

    function test_revert_transferSharesFrom_zeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(IRebasingEquityToken.ZeroAmount.selector);
        token.transferSharesFrom(alice, carol, 0);
    }

    /// @dev The documented trade-off of a token-denominated allowance: its
    ///      purchasing power in SHARES decays as the multiplier rises.
    function test_allowance_purchasingPowerDecaysWithMultiplier() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, 100); // worth 100 shares at 1e18

        _rebase(2e18); // now worth only 50 shares

        vm.prank(bob);
        token.transferFrom(alice, carol, 100);

        assertEq(token.shares(carol), 50, "same allowance now buys half the shares");
        assertEq(token.allowance(alice, bob), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_redeem_burnsExactSharesAndReleasesBacking() public {
        _mint(alice, 1000);

        vm.prank(alice);
        token.redeem(400);

        assertEq(token.shares(alice), 600, "alice shares");
        assertEq(token.totalShares(), 600, "totalShares");
        assertEq(registry.allocatedShares(address(token)), 600, "registry released exactly 400");
    }

    function test_redeem_afterRebase() public {
        _mint(alice, 1000);
        _rebase(2e18);

        vm.prank(alice);
        token.redeem(1000); // full SHARE balance, not token balance

        assertEq(token.shares(alice), 0);
        assertEq(token.totalShares(), 0);
        assertEq(registry.allocatedShares(address(token)), 0);
    }

    function test_revert_redeem_moreThanHeld() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.InsufficientShares.selector, 101, 100));
        token.redeem(101);
    }

    function test_revert_redeem_zeroShares() public {
        _mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert(IRebasingEquityToken.ZeroAmount.selector);
        token.redeem(0);
    }

    function test_event_redeem() public {
        _mint(alice, 1000);
        _rebase(2e18);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(alice, address(0), 800); // 400 shares * 2
        vm.expectEmit(true, true, true, true, address(token));
        emit IRebasingEquityToken.SharesRedeemed(alice, 400, 2e18, 800);

        vm.prank(alice);
        token.redeem(400);
    }

    /*//////////////////////////////////////////////////////////////
                            CORPORATE ACTION
    //////////////////////////////////////////////////////////////*/

    function test_corporateAction_byRole() public {
        _rebase(1.5e18);
        assertEq(token.multiplier(), 1.5e18);
    }

    function test_revert_corporateAction_unauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, CORPORATE_ACTION_ROLE
            )
        );
        token.applyCorporateAction(2e18);
    }

    /// @dev The minting authority cannot rebase.
    function test_revert_corporateAction_fromPrimaryRole() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, minter, CORPORATE_ACTION_ROLE
            )
        );
        token.applyCorporateAction(2e18);
    }

    function test_revert_corporateAction_zeroMultiplier() public {
        vm.prank(corpActor);
        vm.expectRevert(IRebasingEquityToken.InvalidMultiplier.selector);
        token.applyCorporateAction(0);
    }

    function test_revert_corporateAction_sameMultiplier() public {
        vm.prank(corpActor);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.MultiplierNotIncreasing.selector, ONE, ONE));
        token.applyCorporateAction(ONE);
    }

    function test_revert_corporateAction_lowerMultiplier() public {
        _rebase(2e18);

        vm.prank(corpActor);
        vm.expectRevert(abi.encodeWithSelector(IRebasingEquityToken.MultiplierNotIncreasing.selector, 2e18, 1.5e18));
        token.applyCorporateAction(1.5e18);
    }

    /// @dev No per-action cap: a legitimate forward split can exceed 2x.
    function test_corporateAction_largeSplitAllowed() public {
        _mint(alice, 100);
        _rebase(10e18);

        assertEq(token.shares(alice), 100, "shares must not move");
        assertEq(token.balanceOf(alice), 1000);
    }

    function test_event_corporateAction() public {
        _mint(alice, 500);

        vm.expectEmit(true, true, true, true, address(token));
        emit IRebasingEquityToken.CorporateActionApplied(ONE, 1.5e18, 500);

        vm.prank(corpActor);
        token.applyCorporateAction(1.5e18);
    }

    /// @notice Corporate action must leave every share quantity and the registry
    ///         allocation untouched, while moving every derived balance.
    function test_corporateAction_movesBalancesNotShares() public {
        _mint(alice, 100);
        _mint(bob, 300);

        uint256 aliceShares = token.shares(alice);
        uint256 bobShares = token.shares(bob);
        uint256 sharesTotal = token.totalShares();
        uint256 allocated = registry.allocatedShares(address(token));

        _rebase(1.5e18);

        // Shares and backing: EXACTLY unchanged.
        assertEq(token.shares(alice), aliceShares, "alice shares moved");
        assertEq(token.shares(bob), bobShares, "bob shares moved");
        assertEq(token.totalShares(), sharesTotal, "totalShares moved");
        assertEq(registry.allocatedShares(address(token)), allocated, "registry allocation moved");

        // Derived balances: scaled by the multiplier.
        assertEq(token.balanceOf(alice), 150, "alice balance");
        assertEq(token.balanceOf(bob), 450, "bob balance");
        assertEq(token.totalSupply(), 600, "totalSupply");
    }

    /*//////////////////////////////////////////////////////////////
                    HEADLINE: NO VALUE CREATED OR DESTROYED
    //////////////////////////////////////////////////////////////*/

    /// @notice THE HEADLINE PROPERTY: no share value is created or destroyed
    ///         across a rebase, and share conservation survives a post-rebase
    ///         transfer. Share conservation -- not equality of rounded displayed
    ///         balances -- is the correctness property that matters.
    function test_noShareValueCreatedOrDestroyedAcrossRebase() public {
        _mint(alice, 111);
        _mint(bob, 3333);
        _mint(carol, 77777);

        uint256 aliceBefore = token.shares(alice);
        uint256 bobBefore = token.shares(bob);
        uint256 carolBefore = token.shares(carol);
        uint256 totalBefore = token.totalShares();
        uint256 allocatedBefore = registry.allocatedShares(address(token));

        assertEq(totalBefore, aliceBefore + bobBefore + carolBefore, "holders must sum to total");
        assertEq(allocatedBefore, totalBefore, "backing must equal issued shares");

        // ---- corporate action, deliberately not a clean divisor -------------
        _rebase(1.333333333333333333e18);

        // ---- every share quantity EXACTLY unchanged -------------------------
        assertEq(token.shares(alice), aliceBefore, "alice shares changed");
        assertEq(token.shares(bob), bobBefore, "bob shares changed");
        assertEq(token.shares(carol), carolBefore, "carol shares changed");
        assertEq(token.totalShares(), totalBefore, "totalShares changed");
        assertEq(registry.allocatedShares(address(token)), allocatedBefore, "registry allocation changed");

        // ---- backing stays synchronized with issued supply ------------------
        assertEq(registry.allocatedShares(address(token)), token.totalShares(), "backing desynchronized");

        // ---- a transfer after the rebase conserves shares -------------------
        uint256 sumBeforeTransfer = token.shares(alice) + token.shares(bob) + token.shares(carol);

        vm.prank(carol);
        token.transfer(bob, 12345); // an amount the multiplier does not divide cleanly

        uint256 sumAfterTransfer = token.shares(alice) + token.shares(bob) + token.shares(carol);

        assertEq(sumAfterTransfer, sumBeforeTransfer, "transfer created or destroyed shares");
        assertEq(token.totalShares(), totalBefore, "totalShares moved on transfer");
        assertEq(registry.allocatedShares(address(token)), token.totalShares(), "backing desynchronized");
    }

    /*//////////////////////////////////////////////////////////////
                                ROUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice With a multiplier that divides nothing cleanly, transfers must
    ///         still conserve shares exactly.
    function test_rounding_transferConservesSharesAtAwkwardMultiplier() public {
        _mint(alice, 1_000_000);
        _rebase(1.000000000000000001e18);

        uint256 totalBefore = token.totalShares();

        for (uint256 i = 1; i <= 5; ++i) {
            uint256 aliceBefore = token.shares(alice);
            uint256 bobBefore = token.shares(bob);

            vm.prank(alice);
            token.transfer(bob, i * 7777);

            uint256 debited = aliceBefore - token.shares(alice);
            uint256 credited = token.shares(bob) - bobBefore;

            assertEq(debited, credited, "debit != credit");
            assertEq(token.totalShares(), totalBefore, "totalShares moved");
        }
    }

    /// @notice Documented and accepted: per-holder floored balances can sum to
    ///         slightly less than totalSupply, which floors once over the
    ///         aggregate. This is rounding dust in a derived view, not value
    ///         creation -- the share sums above are exact.
    function test_rounding_sumOfBalancesMayBeBelowTotalSupply() public {
        _mint(alice, 1);
        _mint(bob, 1);
        _mint(carol, 1);
        _rebase(1.5e18); // each holder: 1 share -> floor(1.5) == 1 token

        uint256 sumOfBalances = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol);

        // 3 shares * 1.5 == 4 (floored once), but 1+1+1 == 3 per holder.
        assertEq(sumOfBalances, 3, "per-holder floored sum");
        assertEq(token.totalSupply(), 4, "aggregate floored once");
        assertLe(sumOfBalances, token.totalSupply(), "dust must never exceed totalSupply");

        // Shares, the canonical unit, remain exact.
        assertEq(token.shares(alice) + token.shares(bob) + token.shares(carol), token.totalShares());
    }

    /*//////////////////////////////////////////////////////////////
                    AMM INTEGRATION HAZARDS (EXPLICIT)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pins the documented shortfall bound: a token-denominated transfer
    ///         moves at most `amount`, and at least `amount - (multiplier/1e18)`.
    ///         A PancakeSwap V2 pair measures input as a balance delta, so this
    ///         bound is exactly what an AMM integration must tolerate.
    function test_amm_transferShortfallIsBoundedByOneShareValue() public {
        _mint(alice, 1_000_000);
        _rebase(3e18); // one share is worth 3 tokens

        uint256 requested = 100;
        uint256 expectedShares = requested / 3; // 33
        uint256 expectedMoved = expectedShares * 3; // 99

        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, requested);

        uint256 moved = token.balanceOf(bob) - bobBefore;

        assertEq(moved, expectedMoved, "moved value");
        assertLt(moved, requested, "should be a genuine shortfall here");
        // The documented bound: shortfall < token value of one share.
        assertLt(requested - moved, 3e18 / 1e18 + 1, "shortfall exceeded one share value");
    }

    /// @notice THE FINDING THAT DECIDES THE ADAPTER DESIGN: even a share-EXACT
    ///         transfer cannot promise an exact balance delta, because `balanceOf`
    ///         floors the recipient's TOTAL shares and therefore depends on the
    ///         remainder they already held.
    ///
    ///         Consequence: no rounding policy in this token can make a V2 pair's
    ///         measured `balanceOf(pair) - reserve` equal the requested amount. The
    ///         adapter must measure deltas and must use the
    ///         `...SupportingFeeOnTransferTokens` router path.
    function test_amm_exactShareTransferStillYieldsUnpredictableBalanceDelta() public {
        _mint(alice, 1000);
        _mint(bob, 1); // bob carries a share remainder
        _rebase(1.5e18);

        // bob holds 1 share -> floor(1 * 1.5) == 1 token displayed.
        assertEq(token.balanceOf(bob), 1, "bob starting balance");

        uint256 bobBefore = token.balanceOf(bob);

        // Move EXACTLY one share, whose token value is floor(1.5) == 1.
        vm.prank(alice);
        token.transferShares(bob, 1);

        uint256 delta = token.balanceOf(bob) - bobBefore;

        // bob now holds 2 shares -> floor(2 * 1.5) == 3. Delta is 2.
        assertEq(token.balanceOf(bob), 3, "bob final balance");
        assertEq(delta, 2, "balance delta");

        // The delta (2) matches NEITHER the value of the shares moved (1) nor any
        // requested token amount. This is intrinsic, not a bug.
        assertEq(token.sharesToAmount(1), 1, "value of one share, floored");
        assertTrue(delta != token.sharesToAmount(1), "delta must differ from value moved");

        // Shares themselves remain exact -- that is why settlement accounts in shares.
        assertEq(token.shares(bob), 2, "shares are exact");
        assertEq(token.totalShares(), 1001, "shares conserved");
    }

    /// @notice The conversion views let an integrator compute the shortfall up
    ///         front instead of discovering it on a failed swap.
    function test_amm_conversionViewsExposeShortfallBeforeTransfer() public {
        _mint(alice, 1_000_000);
        _rebase(7e18);

        uint256 requested = 1000;
        uint256 resolvedShares = token.amountToShares(requested); // floor(1000/7) == 142
        uint256 willMove = token.sharesToAmount(resolvedShares); // 142 * 7 == 994

        assertEq(resolvedShares, 142);
        assertEq(willMove, 994);
        assertLe(willMove, requested, "views must never promise more than requested");

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(alice);
        token.transfer(bob, requested);

        // The views predicted the actual movement exactly.
        assertEq(token.balanceOf(bob) - bobBefore, willMove, "views mispredicted");
        assertEq(token.shares(bob), resolvedShares, "views mispredicted shares");
    }

    /// @notice A positive rebase inflates a pool-like holder's balance with no
    ///         transfer at all. For a V2 pair this leaves `reserve < balanceOf`,
    ///         which anyone may claim via `skim()`. Documented as an AMM-side
    ///         leak, not something this token can prevent.
    function test_amm_rebaseInflatesHolderBalanceWithNoTransfer() public {
        address pool = makeAddr("pool");
        _mint(pool, 1000);

        uint256 balanceBefore = token.balanceOf(pool);
        uint256 sharesBefore = token.shares(pool);

        _rebase(2e18);

        assertEq(token.shares(pool), sharesBefore, "shares must not move");
        assertEq(token.balanceOf(pool), balanceBefore * 2, "balance doubled with no transfer");
        // A V2 pair's cached reserve would still read balanceBefore here, leaving
        // the difference claimable by the first caller of skim() or swap().
    }

    function test_rounding_transferSharesIsAlwaysExact() public {
        _mint(alice, 1_000_000);
        _rebase(1.000000000000000007e18);

        vm.prank(alice);
        token.transferShares(bob, 999_999);

        assertEq(token.shares(bob), 999_999, "transferShares must be exact");
        assertEq(token.shares(alice), 1, "remainder exact");
        assertEq(token.totalShares(), 1_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Conversion round trip never gains value: converting a token amount
    ///         to shares and back can only lose to flooring, never exceed the
    ///         original.
    function testFuzz_conversionRoundTripNeverGains(uint256 mult, uint256 amount) public {
        mult = bound(mult, ONE, 1_000_000e18);
        amount = bound(amount, 0, type(uint128).max);

        if (mult > ONE) _rebase(mult);

        assertLe(token.toAmount(token.toShares(amount)), amount, "round trip gained value");
    }

    /// @notice Ceil conversion is never below floor, and never more than one
    ///         above it. Used for allowance debits, so it must not overcharge
    ///         wildly either.
    function testFuzz_ceilConversionBounds(uint256 mult, uint256 shareAmount) public {
        mult = bound(mult, ONE, 1_000_000e18);
        shareAmount = bound(shareAmount, 0, type(uint128).max);

        if (mult > ONE) _rebase(mult);

        uint256 floorAmount = token.toAmount(shareAmount);
        uint256 ceilAmount = token.toAmountCeil(shareAmount);

        assertGe(ceilAmount, floorAmount, "ceil below floor");
        assertLe(ceilAmount - floorAmount, 1, "ceil overshot by more than 1");
    }

    /// @notice At any valid multiplier, a transfer debits exactly what it credits
    ///         and leaves totalShares untouched.
    function testFuzz_transferConservesShares(uint256 mult, uint256 mintShares, uint256 amount) public {
        mult = bound(mult, ONE, 1_000_000e18);
        mintShares = bound(mintShares, 1e12, 1e24);

        _mint(alice, mintShares);
        if (mult > ONE) _rebase(mult);

        uint256 aliceBalance = token.balanceOf(alice);
        // Keep the amount large enough to resolve to at least one share, i.e. at
        // least the token value of a single share, rounded up.
        uint256 minAmount = (mult + ONE - 1) / ONE;
        vm.assume(aliceBalance >= minAmount);
        amount = bound(amount, minAmount, aliceBalance);

        uint256 totalBefore = token.totalShares();
        uint256 aliceBefore = token.shares(alice);
        uint256 bobBefore = token.shares(bob);

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 debited = aliceBefore - token.shares(alice);
        uint256 credited = token.shares(bob) - bobBefore;

        assertEq(debited, credited, "debit != credit");
        assertEq(token.totalShares(), totalBefore, "totalShares moved");
        assertEq(registry.allocatedShares(address(token)), totalBefore, "backing moved");
    }

    /// @notice mint -> rebase -> redeem the full SHARE balance always succeeds and
    ///         releases exactly the shares that were allocated.
    function testFuzz_mintRebaseRedeemFullShareBalance(uint256 mintShares, uint256 mult) public {
        mintShares = bound(mintShares, 1, 1e24);
        mult = bound(mult, ONE + 1, 1_000_000e18);

        _mint(alice, mintShares);
        uint256 allocatedAfterMint = registry.allocatedShares(address(token));
        assertEq(allocatedAfterMint, mintShares, "mint did not allocate exactly");

        _rebase(mult);

        // Shares survived the rebase untouched, so the full share balance is
        // still exactly what was minted.
        assertEq(token.shares(alice), mintShares, "rebase moved shares");

        // Read before the prank; an external call in the argument list would
        // consume it and send `redeem` from the test contract instead.
        uint256 fullShareBalance = token.shares(alice);

        vm.prank(alice);
        token.redeem(fullShareBalance);

        assertEq(token.shares(alice), 0, "shares not fully burned");
        assertEq(token.totalShares(), 0, "totalShares not zero");
        assertEq(
            registry.allocatedShares(address(token)),
            allocatedAfterMint - mintShares,
            "registry allocation did not decrease by exactly the redeemed shares"
        );
    }

    /*//////////////////////////////////////////////////////////////
              CONVERSION REGRESSION PROPERTIES — FLOOR/CEIL PAIR

        These pin the relationship between the FLOOR conversion used to resolve
        a token amount to shares and the CEIL conversion used to debit an
        allowance. The two round in opposite directions on purpose, and the
        properties below are what make that safe rather than merely asymmetric.

        ================== SCOPE — A4 ONLY, NOT A5 ==================
        These properties cover the A4 case ONLY: `sharesIn` is RECOMPUTED from
        `o.amountIn` at the SETTLEMENT-TIME multiplier, so the derivation

            S = floor(A * 1e18 / m)

        holds by construction and the allowance always fits. That is
        multiplier-independent: whatever m is at settlement, S is derived from
        it, so the ceil of S can never exceed A.

        They do NOT cover the A5 case. There, a share quantity S is FIXED at
        approval time via `approveShares(S)` and consumed LATER at a different
        multiplier. S was not derived from the current allowance, so the proof
        above does not apply: a stored token allowance of
        ceil(S * m_old / 1e18) permits strictly FEWER than S shares once
        m > m_old. That is a liveness failure — the sell reverts with
        InsufficientAllowance — and it is what a `topUpEngineShares` path
        exists to fix. NOTHING IN THIS FILE MAKES THAT TOP-UP REDUNDANT.
        =============================================================
    //////////////////////////////////////////////////////////////*/

    /// @dev PROOF, recorded so a future reader does not have to re-derive it:
    ///
    ///        S = floor(A * 1e18 / m)   =>   S * m / 1e18 <= A
    ///
    ///      A is an integer and A >= S * m / 1e18. `ceil` is the LEAST integer
    ///      that is >= its argument, so ceil(S * m / 1e18) <= A.
    ///
    ///      Holds for EVERY m — there is no lower bound on the multiplier
    ///      required here, unlike the round-trip property below.
    function test_CeilOfFlooredSharesNeverExceedsOriginalAmount() public {
        // Strictly increasing: the multiplier is up-only, so the table has to be
        // walked in order. Covers parity, one wei above parity, a non-dividing
        // fractional multiplier, and a large one.
        uint256[5] memory multipliers = [ONE, ONE + 1, 1.333e18, 7e18, 1e24];

        // Chosen so A * 1e18 does not divide evenly by the multipliers above.
        uint256[6] memory amounts = [uint256(1), 3, 999, 12_345_678_901_234_567, ONE + 7, 1e24 + 13];

        for (uint256 i; i < multipliers.length; ++i) {
            // The first entry IS the deployed multiplier, and the token is
            // up-only, so rebasing to it would revert MultiplierNotIncreasing.
            if (multipliers[i] > token.multiplier()) _rebase(multipliers[i]);

            for (uint256 j; j < amounts.length; ++j) {
                uint256 a = amounts[j];
                uint256 s = token.amountToShares(a);
                assertLe(
                    token.toAmountCeil(s), a, "ceil(floor(A)) exceeded A -- an allowance debit could exceed approval"
                );
            }
        }
    }

    /// @dev PROOF, and note what it depends on:
    ///
    ///        T = ceil(S * m / 1e18)  <  S * m / 1e18 + 1
    ///
    ///      so in SHARE terms
    ///
    ///        T * 1e18 / m - S  <  1e18 / m
    ///
    ///      At m >= 1e18 that residual is strictly less than ONE share-unit, so
    ///      the floor recovers S exactly. The bound TIGHTENS as m grows.
    ///
    ///      THIS IS A PROPERTY THE UP-ONLY DECISION PURCHASES, NOT A PROPERTY OF
    ///      THE ARITHMETIC ALONE. A bidirectional multiplier would allow
    ///      m < 1e18, where 1e18 / m exceeds one share-unit and this equality
    ///      degrades to `>=`. If the up-only policy is ever revisited, this test
    ///      is one of the things that breaks, and it should be read as a cost of
    ///      that change rather than a broken test.
    function test_ShareRoundTripIsLosslessUnderUpOnlyMultiplier() public {
        uint256[5] memory multipliers = [ONE, ONE + 1, 1.333e18, 7e18, 1e24];
        uint256[6] memory shareAmounts = [uint256(1), 2, 1_000, 999_999_999_999_999_999, ONE + 5, 1e24 + 3];

        for (uint256 i; i < multipliers.length; ++i) {
            // The first entry IS the deployed multiplier, and the token is
            // up-only, so rebasing to it would revert MultiplierNotIncreasing.
            if (multipliers[i] > token.multiplier()) _rebase(multipliers[i]);

            for (uint256 j; j < shareAmounts.length; ++j) {
                uint256 s = shareAmounts[j];
                assertEq(token.amountToShares(token.toAmountCeil(s)), s, "share round trip was lossy at m >= 1e18");
            }
        }
    }

    /// @dev Named `testFuzz_` rather than `fuzz_`: Foundry only collects functions
    ///      whose name begins with `test`, so a `fuzz_`-prefixed function would
    ///      compile, appear to exist, and silently never run.
    function testFuzz_CeilOfFlooredSharesNeverExceedsOriginalAmount(uint256 a, uint256 m) public {
        m = bound(m, ONE, 1e24);
        a = bound(a, 1, 1e30);

        if (m > ONE) _rebase(m);

        uint256 s = token.amountToShares(a);
        assertLe(token.toAmountCeil(s), a, "ceil(floor(A)) exceeded A");
    }

    function testFuzz_ShareRoundTripLossless(uint256 s, uint256 m) public {
        m = bound(m, ONE, 1e24);
        s = bound(s, 1, 1e30);

        if (m > ONE) _rebase(m);

        assertEq(token.amountToShares(token.toAmountCeil(s)), s, "share round trip was lossy");
    }

    /*//////////////////////////////////////////////////////////////
        INVERSE DIRECTION — CEIL RECOVERS A FLOOR'D SHARE QUANTITY

        The two properties above cover ceil-then-floor: a share quantity is
        ceiled to a token amount and the floor conversion recovers it. The two
        below cover the OPPOSITE composition, floor-then-ceil, which is the one
        the Settlement Engine's sell path actually produces.

        WHY THIS PAIRING AND NOT ANOTHER. On a sell the Engine derives

            executableAmountIn = sharesToAmount(sharesIn)   -- a FLOOR

        so any consumer handed that figure and needing the share quantity back
        must invert a floor, and only a CEIL does that losslessly. Inverting it
        with `amountToShares` — the floor conversion — would land one share low
        whenever the multiplier does not divide cleanly.

        SAME PRECONDITION AS ABOVE: m >= 1e18, purchased by the up-only
        multiplier policy. Both directions break together if that is revisited.
    //////////////////////////////////////////////////////////////*/

    /// @notice `amountToSharesCeil` recovers the Engine's `sharesIn` exactly from
    ///         the `executableAmountIn` the Engine derived from it.
    /// @dev `T` is built with the EXISTING floor helper `sharesToAmount`, i.e.
    ///      literally the call [`SettlementEngine._toAmount`] makes, so this test
    ///      exercises the real composition rather than a re-derivation of it.
    function test_AmountToSharesCeilInvertsExecutableAmountExactly() public {
        // Strictly increasing: the multiplier is up-only, so the table must be
        // walked in order. Parity, one wei above parity, a non-dividing
        // fractional multiplier, and a large one.
        uint256[5] memory multipliers = [ONE, ONE + 1, 1.333e18, 7e18, 1e24];

        // Chosen so `sharesIn * m` does not divide evenly by 1e18 for most
        // entries above, forcing the floor to actually truncate.
        uint256[6] memory shareAmounts = [uint256(1), 2, 1_000, 999_999_999_999_999_999, ONE + 5, 1e24 + 3];

        for (uint256 i; i < multipliers.length; ++i) {
            // The first entry IS the deployed multiplier, and the token is
            // up-only, so rebasing to it would revert MultiplierNotIncreasing.
            if (multipliers[i] > token.multiplier()) _rebase(multipliers[i]);

            for (uint256 j; j < shareAmounts.length; ++j) {
                uint256 sharesIn = shareAmounts[j];

                // Exactly what SettlementEngine STEP 2 computes on a sell.
                uint256 executableAmountIn = token.sharesToAmount(sharesIn);

                assertEq(
                    token.amountToSharesCeil(executableAmountIn),
                    sharesIn,
                    "ceil did not recover sharesIn from the floored executable amount"
                );
            }
        }
    }

    /// @dev Named `testFuzz_` rather than `fuzz_` for the reason recorded on
    ///      {testFuzz_CeilOfFlooredSharesNeverExceedsOriginalAmount}: Foundry
    ///      collects only `test`-prefixed functions, so a `fuzz_`-prefixed one
    ///      would compile, appear to exist, and silently never run.
    ///
    ///      `T` is computed INDEPENDENTLY here — `mulDiv` in the test rather than
    ///      the token's own helper — so the assertion cannot be satisfied by two
    ///      copies of the same bug. `Math.mulDiv` and not `sharesIn * m / ONE`
    ///      because at the bounds below the product overflows uint256.
    function testFuzz_AmountToSharesCeilRoundTripLossless(uint256 sharesIn, uint256 m) public {
        m = bound(m, ONE, 1e24);
        sharesIn = bound(sharesIn, 1, 1e30);

        if (m > ONE) _rebase(m);

        uint256 T = Math.mulDiv(sharesIn, m, ONE);

        assertEq(token.amountToSharesCeil(T), sharesIn, "floor-then-ceil round trip was lossy");
    }
}
