// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrimaryReserveVault} from "../src/primary/PrimaryReserveVault.sol";
import {MockStable} from "./mocks/SettlementMocks.sol";

/*//////////////////////////////////////////////////////////////////////////
                        SHARED FIXTURE
//////////////////////////////////////////////////////////////////////////*/

abstract contract PrimaryReserveVaultFixture is Test {
    PrimaryReserveVault internal vault;
    MockStable internal stable;

    address internal admin = makeAddr("admin");
    address internal adapter = makeAddr("adapter");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant SEED = 1_000e18;

    /// @dev Hardcoded rather than read from the vault: a getter call would be an
    ///      external call that consumes a pending `vm.prank`, and a test should
    ///      not assert a contract against its own getter.
    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal constant ADAPTER_ROLE = keccak256("ADAPTER_ROLE");

    function _deployAndWire() internal {
        stable = new MockStable("Mock Stable", "mUSD");
        vault = new PrimaryReserveVault(IERC20(address(stable)), admin);

        // ADAPTER_ROLE is granted post-deploy, mirroring the real wiring: the
        // adapter needs the vault's address to be constructed, so the two
        // cannot be linked in a single transaction.
        vm.prank(admin);
        vault.grantRole(ADAPTER_ROLE, adapter);
    }

    /// @dev Funds the vault through the real {adminDeposit} path rather than by
    ///      minting straight to it, so the fixture exercises the same code a
    ///      live capitalization would.
    function _seed(uint256 amount) internal {
        stable.mint(admin, amount);

        vm.startPrank(admin);
        stable.approve(address(vault), amount);
        vault.adminDeposit(amount);
        vm.stopPrank();
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        UNIT + FUZZ TESTS
//////////////////////////////////////////////////////////////////////////*/

contract PrimaryReserveVaultTest is PrimaryReserveVaultFixture {
    function setUp() public {
        _deployAndWire();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_initialState() public view {
        assertEq(address(vault.stable()), address(stable), "stable not wired");
        assertEq(vault.minReserveBuffer(), 0, "buffer should default to 0");
        assertEq(vault.reserveBalance(), 0, "fresh vault should hold nothing");
        assertTrue(vault.hasRole(ADMIN_ROLE, admin), "admin lacks DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(ADAPTER_ROLE, adapter), "adapter lacks ADAPTER_ROLE");
    }

    /// @dev The admin is deliberately NOT granted ADAPTER_ROLE by the
    ///      constructor. Asserted so a future change that quietly grants it
    ///      shows up here rather than in production.
    function test_initialState_adminIsNotAdapter() public view {
        assertFalse(vault.hasRole(ADAPTER_ROLE, admin), "admin must not hold ADAPTER_ROLE by default");
    }

    function test_revert_constructor_zeroStable() public {
        vm.expectRevert(PrimaryReserveVault.ZeroAddress.selector);
        new PrimaryReserveVault(IERC20(address(0)), admin);
    }

    function test_revert_constructor_zeroAdmin() public {
        vm.expectRevert(PrimaryReserveVault.ZeroAddress.selector);
        new PrimaryReserveVault(IERC20(address(stable)), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_adminDeposit_increasesReserveBalance() public {
        stable.mint(admin, SEED);

        vm.startPrank(admin);
        stable.approve(address(vault), SEED);
        vault.adminDeposit(SEED);
        vm.stopPrank();

        assertEq(vault.reserveBalance(), SEED, "reserve did not increase by the deposit");
        assertEq(stable.balanceOf(admin), 0, "deposit did not debit the depositor");
    }

    function test_adminDeposit_accumulates() public {
        _seed(SEED);
        _seed(SEED);

        assertEq(vault.reserveBalance(), 2 * SEED, "deposits did not accumulate");
    }

    function test_event_adminDeposit() public {
        stable.mint(admin, SEED);

        vm.prank(admin);
        stable.approve(address(vault), SEED);

        vm.expectEmit(true, true, true, true, address(vault));
        emit PrimaryReserveVault.AdminDeposited(SEED);

        vm.prank(admin);
        vault.adminDeposit(SEED);
    }

    function test_revert_adminDeposit_fromNonAdmin() public {
        stable.mint(stranger, SEED);

        vm.prank(stranger);
        stable.approve(address(vault), SEED);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        vm.prank(stranger);
        vault.adminDeposit(SEED);
    }

    /*//////////////////////////////////////////////////////////////
                          ADAPTER PATH: WITHDRAW TO
    //////////////////////////////////////////////////////////////*/

    function test_withdrawTo_fromAdapterRole_reducesReserveBalance() public {
        _seed(SEED);

        uint256 amount = 400e18;

        vm.prank(adapter);
        vault.withdrawTo(recipient, amount);

        assertEq(vault.reserveBalance(), SEED - amount, "reserve did not fall by the withdrawal");
        assertEq(stable.balanceOf(recipient), amount, "recipient was not paid");
    }

    function test_withdrawTo_fullBalance() public {
        _seed(SEED);

        vm.prank(adapter);
        vault.withdrawTo(recipient, SEED);

        assertEq(vault.reserveBalance(), 0, "full withdrawal left a residue");
        assertEq(stable.balanceOf(recipient), SEED, "recipient underpaid");
    }

    function test_event_withdrawTo() public {
        _seed(SEED);

        vm.expectEmit(true, true, true, true, address(vault));
        emit PrimaryReserveVault.Withdrawn(recipient, 1e18);

        vm.prank(adapter);
        vault.withdrawTo(recipient, 1e18);
    }

    function test_revert_withdrawTo_fromNonAdapter() public {
        _seed(SEED);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADAPTER_ROLE)
        );
        vm.prank(stranger);
        vault.withdrawTo(recipient, 1e18);
    }

    /// @dev The ADMIN is a non-adapter for this purpose. Holding
    ///      DEFAULT_ADMIN_ROLE does not confer ADAPTER_ROLE — the admin can
    ///      grant itself that role, but must do so explicitly, and until it
    ///      does this path is closed to it.
    function test_revert_withdrawTo_fromAdminWithoutAdapterRole() public {
        _seed(SEED);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, ADAPTER_ROLE)
        );
        vm.prank(admin);
        vault.withdrawTo(recipient, 1e18);
    }

    function test_revert_withdrawTo_moreThanReserveBalance() public {
        _seed(SEED);

        vm.expectRevert(PrimaryReserveVault.InsufficientReserve.selector);
        vm.prank(adapter);
        vault.withdrawTo(recipient, SEED + 1);
    }

    /// @dev The buffer constrains admin outflows ONLY. A settlement-driven pull
    ///      by the adapter is not an admin outflow, so it may legitimately take
    ///      the reserve to zero even with a large buffer set. Pinned here
    ///      because gating {withdrawTo} on the buffer would revert live
    ///      settlements, and that would be a plausible-looking "fix".
    function test_withdrawTo_isNotConstrainedByMinReserveBuffer() public {
        _seed(SEED);

        vm.prank(admin);
        vault.setMinReserveBuffer(SEED);

        vm.prank(adapter);
        vault.withdrawTo(recipient, SEED);

        assertEq(vault.reserveBalance(), 0, "adapter pull was blocked by the admin-only buffer");
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_adminWithdraw_reducesReserveBalance() public {
        _seed(SEED);

        vm.prank(admin);
        vault.adminWithdraw(recipient, 250e18);

        assertEq(vault.reserveBalance(), SEED - 250e18, "reserve did not fall by the withdrawal");
        assertEq(stable.balanceOf(recipient), 250e18, "recipient was not paid");
    }

    function test_event_adminWithdraw() public {
        _seed(SEED);

        vm.expectEmit(true, true, true, true, address(vault));
        emit PrimaryReserveVault.AdminWithdrawn(recipient, 1e18);

        vm.prank(admin);
        vault.adminWithdraw(recipient, 1e18);
    }

    function test_revert_adminWithdraw_belowMinReserveBuffer() public {
        _seed(SEED);

        vm.prank(admin);
        vault.setMinReserveBuffer(600e18);

        // Leaves 599e18, one wei-token below the floor.
        vm.expectRevert(PrimaryReserveVault.BelowMinReserveBuffer.selector);
        vm.prank(admin);
        vault.adminWithdraw(recipient, 401e18);
    }

    /// @dev The buffer check is strict (`<`), so withdrawing down to EXACTLY the
    ///      buffer is allowed. Pins which side of the boundary is permitted.
    function test_adminWithdraw_downToExactlyBufferIsAllowed() public {
        _seed(SEED);

        vm.prank(admin);
        vault.setMinReserveBuffer(600e18);

        vm.prank(admin);
        vault.adminWithdraw(recipient, 400e18);

        assertEq(vault.reserveBalance(), 600e18, "withdrawal to exactly the buffer should succeed");
    }

    function test_revert_adminWithdraw_fromNonAdmin() public {
        _seed(SEED);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        vm.prank(stranger);
        vault.adminWithdraw(recipient, 1e18);
    }

    /// @dev The adapter's role does not extend to the admin path either. The two
    ///      outflow routes are separately gated in both directions.
    function test_revert_adminWithdraw_fromAdapter() public {
        _seed(SEED);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, adapter, ADMIN_ROLE)
        );
        vm.prank(adapter);
        vault.adminWithdraw(recipient, 1e18);
    }

    /// @dev THE ORDERING TEST. `amount` exceeds the balance AND the buffer check
    ///      would underflow, so this distinguishes the two failure modes: the
    ///      sufficiency check must fire first and produce a named error, not a
    ///      `Panic(0x11)` from inside `balance - amount`.
    function test_revert_adminWithdraw_moreThanBalanceGivesInsufficientReserveNotPanic() public {
        _seed(SEED);

        vm.prank(admin);
        vault.setMinReserveBuffer(100e18);

        vm.expectRevert(PrimaryReserveVault.InsufficientReserve.selector);
        vm.prank(admin);
        vault.adminWithdraw(recipient, SEED + 1);
    }

    /// @dev Same ordering, with the buffer at zero — so the ONLY thing standing
    ///      between the caller and an arithmetic panic is the explicit
    ///      sufficiency check. If that check were removed, `balance - amount`
    ///      would underflow and this test would report a panic instead.
    function test_revert_adminWithdraw_overdrawOnEmptyVaultWithZeroBuffer() public {
        vm.expectRevert(PrimaryReserveVault.InsufficientReserve.selector);
        vm.prank(admin);
        vault.adminWithdraw(recipient, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          SET MIN RESERVE BUFFER
    //////////////////////////////////////////////////////////////*/

    function test_setMinReserveBuffer_stores() public {
        vm.prank(admin);
        vault.setMinReserveBuffer(123e18);

        assertEq(vault.minReserveBuffer(), 123e18, "buffer not stored");
    }

    function test_event_setMinReserveBuffer() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrimaryReserveVault.MinReserveBufferSet(7e18);

        vm.prank(admin);
        vault.setMinReserveBuffer(7e18);
    }

    /// @dev A buffer above the current balance is legal — an operator declaring
    ///      a target it intends to fund. The consequence is that admin
    ///      withdrawals are frozen, NOT that a deposit is compelled: nothing in
    ///      this contract acts on the gap. See the {minReserveBuffer} note.
    function test_setMinReserveBuffer_maySitAboveCurrentBalance() public {
        _seed(SEED);

        vm.prank(admin);
        vault.setMinReserveBuffer(SEED * 2);

        assertEq(vault.minReserveBuffer(), SEED * 2, "buffer above balance should be permitted");

        vm.expectRevert(PrimaryReserveVault.BelowMinReserveBuffer.selector);
        vm.prank(admin);
        vault.adminWithdraw(recipient, 1);

        // And the vault took no action of its own to close the gap.
        assertEq(vault.reserveBalance(), SEED, "vault moved funds on its own");
    }

    function test_revert_setMinReserveBuffer_fromNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, ADMIN_ROLE)
        );
        vm.prank(stranger);
        vault.setMinReserveBuffer(1);
    }

    /*//////////////////////////////////////////////////////////////
                         SCOPE OF minReserveBuffer

        The buffer is a floor on admin-initiated outflows and NOTHING else.
        The tests below pin the things it does NOT do, because the name
        invites the opposite reading and a future reader is more likely to
        over-trust it than under-trust it.
    //////////////////////////////////////////////////////////////*/

    /// @dev Setting a buffer moves no funds and does not recapitalize. Raising
    ///      it on an under-funded vault leaves the balance exactly where it was.
    function test_scope_bufferDoesNotRecapitalize() public {
        _seed(100e18);

        vm.prank(admin);
        vault.setMinReserveBuffer(10_000e18);

        assertEq(vault.reserveBalance(), 100e18, "setting a buffer must not move funds");
    }

    /// @dev A vault sitting below its buffer is not a state this contract
    ///      detects, reports, or acts on. The adapter can still drain it
    ///      completely, and the balance only changes because someone called a
    ///      function — never because the buffer was breached.
    function test_scope_bufferDoesNotBlockOrDetectReserveDepletion() public {
        _seed(SEED);

        vm.prank(admin);
        vault.setMinReserveBuffer(SEED);

        // Settlement-driven outflow takes it to zero, far below the buffer.
        vm.prank(adapter);
        vault.withdrawTo(recipient, SEED);

        assertEq(vault.reserveBalance(), 0, "adapter pull should be unconstrained");
        assertEq(vault.minReserveBuffer(), SEED, "buffer should be unchanged by the breach");

        // Time passing changes nothing: there is no keeper, no accrual, no
        // self-healing path. The only route back up is an explicit deposit.
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.reserveBalance(), 0, "vault restored itself, which it must not do");
    }

    /// @dev Recapitalization is {adminDeposit} and only {adminDeposit} — an
    ///      externally triggered operator action. The buffer plays no part in
    ///      triggering or sizing it: here the deposit deliberately does not
    ///      reach the buffer, and the vault neither complains nor tops itself
    ///      up the rest of the way.
    function test_scope_recapitalizationIsAdminDepositOnly() public {
        vm.prank(admin);
        vault.setMinReserveBuffer(SEED);

        _seed(100e18);

        assertEq(vault.reserveBalance(), 100e18, "deposit was resized by the buffer");
        assertLt(vault.reserveBalance(), vault.minReserveBuffer(), "expected to remain under-funded");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice {adminWithdraw} NEVER PANICS. For any `amount` in the whole
    ///         uint256 range it either succeeds or reverts with one of two
    ///         named errors. A raw arithmetic panic is never an acceptable
    ///         outcome.
    /// @dev This is the property the check ordering in {adminWithdraw} exists to
    ///      guarantee, so it is asserted directly rather than inferred.
    ///
    ///      A low-level `call` is used instead of `vm.expectRevert` because the
    ///      point is to INSPECT the returned selector rather than to assert one
    ///      known outcome — all three outcomes are legal, and the test must
    ///      distinguish a named revert from `Panic(uint256)`, which
    ///      `expectRevert` with a wildcard would happily accept.
    ///
    ///      Named `testFuzz_` rather than `fuzz_`: Foundry collects only
    ///      `test`-prefixed functions, so a `fuzz_`-prefixed one would compile,
    ///      appear to exist, and silently never run.
    function testFuzz_AdminWithdrawNeverPanics(uint256 amount) public {
        _seed(SEED);

        // A nonzero buffer, so the BelowMinReserveBuffer branch is reachable and
        // the two failure modes genuinely overlap for large `amount`.
        vm.prank(admin);
        vault.setMinReserveBuffer(400e18);

        // `Panic(uint256)`. 0x11 is arithmetic overflow/underflow, which is what
        // a missing sufficiency check in adminWithdraw would produce.
        bytes4 panicSelector = 0x4e487b71;

        // Read before the prank: an external call here would consume it.
        uint256 balanceBefore = vault.reserveBalance();

        vm.prank(admin);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(PrimaryReserveVault.adminWithdraw, (recipient, amount)));

        if (ok) {
            // Success is only legal when both conditions actually held.
            assertLe(amount, balanceBefore, "succeeded while overdrawing");
            assertGe(balanceBefore - amount, vault.minReserveBuffer(), "succeeded below the buffer");
            assertEq(vault.reserveBalance(), balanceBefore - amount, "balance did not match the withdrawal");
            return;
        }

        assertGe(ret.length, 4, "reverted with no error data -- a bare revert is not a named failure");

        bytes4 selector = bytes4(ret);

        assertTrue(selector != panicSelector, "adminWithdraw panicked instead of reverting with a named error");
        assertTrue(
            selector == PrimaryReserveVault.InsufficientReserve.selector
                || selector == PrimaryReserveVault.BelowMinReserveBuffer.selector,
            "reverted with an unexpected error"
        );

        // A failed call must leave the reserve untouched.
        assertEq(vault.reserveBalance(), balanceBefore, "failed withdrawal moved funds");
    }

    /// @notice Over any sequence of deposits and withdrawals, `reserveBalance()`
    ///         equals the net of the operations that actually SUCCEEDED.
    /// @dev Failed operations must contribute nothing, which is the real content
    ///      here: a reverted withdrawal that still moved funds, or a partially
    ///      applied one, would break this even though every individual unit test
    ///      above would still pass.
    ///
    ///      Both outflow paths are exercised — the adapter's {withdrawTo} and
    ///      the admin's {adminWithdraw} — because they are separately
    ///      implemented and only one of them consults the buffer.
    ///
    ///      `expected` is accumulated in the test from requested amounts, and a
    ///      standard ERC-20 moves exactly what is requested, so this doubles as
    ///      a check that no path silently transfers a different quantity than
    ///      the one it was asked for.
    function testFuzz_ReserveBalanceIsNetOfSuccessfulOperations(uint256[8] memory amounts, uint8 opBits, uint256 buffer)
        public
    {
        buffer = bound(buffer, 0, 500e18);

        vm.prank(admin);
        vault.setMinReserveBuffer(buffer);

        uint256 expected;

        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = bound(amounts[i], 0, 1_000e18);
            uint256 op = (uint256(opBits) >> i) & 1;

            if (op == 1) {
                // Deposit. Always succeeds: the admin is funded and approves
                // exactly this amount immediately beforehand.
                stable.mint(admin, amount);

                vm.startPrank(admin);
                stable.approve(address(vault), amount);
                vault.adminDeposit(amount);
                vm.stopPrank();

                expected += amount;
            } else {
                // Alternate the two outflow paths so both are covered, and so
                // the buffer constrains some iterations but not others.
                bool viaAdapter = (i % 2 == 0);

                vm.prank(viaAdapter ? adapter : admin);
                (bool ok,) = address(vault)
                    .call(
                        viaAdapter
                            ? abi.encodeCall(PrimaryReserveVault.withdrawTo, (recipient, amount))
                            : abi.encodeCall(PrimaryReserveVault.adminWithdraw, (recipient, amount))
                    );

                // ONLY a successful call changes the expected net. This is the
                // assertion that a failed withdrawal is a true no-op.
                if (ok) expected -= amount;
            }

            assertEq(vault.reserveBalance(), expected, "reserve diverged from the net of successful operations");
        }
    }
}
