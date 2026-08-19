// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {MockRebasingEquityToken} from "../../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../../src/mocks/MockShareRegistry.sol";
import {IShareRegistry} from "../../src/interfaces/IShareRegistry.sol";

/*//////////////////////////////////////////////////////////////////////////
                            INVARIANT HANDLER
//////////////////////////////////////////////////////////////////////////*/

/// @dev Drives the token through bounded, always-valid actions and mirrors share
///      accounting in ghost variables.
///
///      Actions are bounded to legal ranges rather than left to revert, so every
///      fuzz call does real work — an invariant suite where most calls bounce off
///      a guard proves nothing. Call counters are exposed so the run summary can
///      show which paths were actually exercised.
///
///      The actor set is CLOSED: shares are only ever minted to a tracked actor
///      and only ever transferred between tracked actors. That is what makes
///      `sum(shares(actors)) == totalShares()` a meaningful statement rather than
///      an accident.
contract RebasingTokenHandler is Test {
    MockRebasingEquityToken public immutable token;
    MockShareRegistry public immutable registry;

    address[3] public actors;

    /// @dev Ghost accounting for share conservation.
    uint256 public totalSharesMinted;
    uint256 public totalSharesRedeemed;

    /// @dev Highest multiplier ever observed, for the monotonicity invariant.
    uint256 public maxMultiplierSeen;

    // Call counters.
    uint256 public mintCalls;
    uint256 public redeemCalls;
    uint256 public transferCalls;
    uint256 public transferSharesCalls;
    uint256 public corporateActionCalls;
    uint256 public skippedNoBacking;
    uint256 public skippedNoShares;
    uint256 public skippedDustTransfer;

    /// @dev Bounds chosen so the handler can never itself be the cause of an
    ///      overflow: max supply value is ~1e24 shares * ~1e24 multiplier, far
    ///      inside uint256. If an overflow appears, it is the contract's fault.
    uint256 internal constant MAX_MINT = 1e24;
    uint256 internal constant MAX_MULTIPLIER = 1e24;

    constructor(MockRebasingEquityToken token_, MockShareRegistry registry_, address[3] memory actors_) {
        token = token_;
        registry = registry_;
        actors = actors_;
        maxMultiplierSeen = token_.multiplier();
    }

    /// @dev Asserts the multiplier never went backwards since the last action and
    ///      records the current value. Applied to every action, so a decrease
    ///      anywhere is caught by the next call as well as by the invariant.
    modifier trackMultiplier() {
        uint256 current = token.multiplier();
        assertGe(current, maxMultiplierSeen, "multiplier decreased");
        maxMultiplierSeen = current;
        _;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZABLE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 actorSeed, uint256 shareAmount) external trackMultiplier {
        address to = _actor(actorSeed);

        uint256 available = registry.availableShares(address(token));
        if (available == 0) {
            skippedNoBacking++;
            return;
        }

        shareAmount = bound(shareAmount, 1, available > MAX_MINT ? MAX_MINT : available);

        token.mint(to, shareAmount);

        totalSharesMinted += shareAmount;
        mintCalls++;
    }

    function redeem(uint256 actorSeed, uint256 shareAmount) external trackMultiplier {
        address from = _actor(actorSeed);

        uint256 held = token.shares(from);
        if (held == 0) {
            skippedNoShares++;
            return;
        }

        shareAmount = bound(shareAmount, 1, held);

        vm.prank(from);
        token.redeem(shareAmount);

        totalSharesRedeemed += shareAmount;
        redeemCalls++;
    }

    /// @dev Token-denominated transfer. Bounded to an amount that resolves to at
    ///      least one share, since a dust amount is a legitimate revert.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external trackMultiplier {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 balance = token.balanceOf(from);
        // Smallest token amount worth at least one share, rounded up.
        uint256 minAmount = (token.multiplier() + 1e18 - 1) / 1e18;
        if (balance < minAmount) {
            skippedDustTransfer++;
            return;
        }

        amount = bound(amount, minAmount, balance);

        vm.prank(from);
        token.transfer(to, amount);

        transferCalls++;
    }

    /// @dev Share-exact transfer. Always exact, so no dust guard is needed.
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 shareAmount) external trackMultiplier {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 held = token.shares(from);
        if (held == 0) {
            skippedNoShares++;
            return;
        }

        shareAmount = bound(shareAmount, 1, held);

        vm.prank(from);
        token.transferShares(to, shareAmount);

        transferSharesCalls++;
    }

    /// @dev Up-only, matching the token's policy. Bounded so the multiplier
    ///      cannot climb far enough to overflow a derived balance.
    function applyCorporateAction(uint256 increase) external trackMultiplier {
        uint256 current = token.multiplier();
        if (current >= MAX_MULTIPLIER) return;

        increase = bound(increase, 1, MAX_MULTIPLIER - current);

        token.applyCorporateAction(current + increase);

        maxMultiplierSeen = current + increase;
        corporateActionCalls++;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                            INVARIANT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract RebasingTokenInvariantTest is Test {
    MockRebasingEquityToken internal token;
    MockShareRegistry internal registry;
    RebasingTokenHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bytes32 internal constant PRIMARY_ROLE = keccak256("PRIMARY_ROLE");
    bytes32 internal constant CORPORATE_ACTION_ROLE = keccak256("CORPORATE_ACTION_ROLE");

    uint256 internal constant CUSTODIED = 1e27;

    function setUp() public {
        registry = new MockShareRegistry(admin);
        token = new MockRebasingEquityToken("Mock Equity", "mEQ", admin, IShareRegistry(address(registry)));
        handler = new RebasingTokenHandler(token, registry, [alice, bob, carol]);

        vm.startPrank(admin);
        registry.registerToken(address(token));
        registry.setCustodiedShares(address(token), CUSTODIED);
        // The handler drives both privileged paths, so it holds both roles for
        // the run. Role SEPARATION is proven by the unit tests; this suite is
        // about accounting correctness under arbitrary action sequences.
        token.grantRole(PRIMARY_ROLE, address(handler));
        token.grantRole(CORPORATE_ACTION_ROLE, address(handler));
        vm.stopPrank();

        targetContract(address(handler));
    }

    function _actors() internal view returns (address[3] memory) {
        return [alice, bob, carol];
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 1
    //////////////////////////////////////////////////////////////*/

    /// @notice totalShares == totalSharesMinted - totalSharesRedeemed.
    ///         Shares enter supply only by mint and leave only by redeem. In
    ///         particular, no corporate action and no transfer may change the
    ///         total — and the handler performs thousands of both.
    function invariant_totalSharesEqualsNetMintFlow() public view {
        assertEq(
            token.totalShares(),
            handler.totalSharesMinted() - handler.totalSharesRedeemed(),
            "totalShares diverged from net mint flow"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 2
    //////////////////////////////////////////////////////////////*/

    /// @notice sum(shares(actor)) == totalShares. No shares hide outside the
    ///         tracked actor set, and transfers move shares without leaking any.
    function invariant_sumOfActorSharesEqualsTotalShares() public view {
        address[3] memory actors = _actors();
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.shares(actors[i]);
        }
        assertEq(sum, token.totalShares(), "actor shares do not sum to totalShares");
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 3
    //////////////////////////////////////////////////////////////*/

    /// @notice The multiplier is monotonically non-decreasing — the up-only
    ///         rebase policy holds across every action sequence.
    function invariant_multiplierIsMonotonic() public view {
        assertGe(token.multiplier(), handler.maxMultiplierSeen(), "multiplier decreased");
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 4
    //////////////////////////////////////////////////////////////*/

    /// @notice sum(balanceOf(actor)) <= totalSupply(). Per-holder balances floor
    ///         independently while totalSupply floors once over the aggregate, so
    ///         the sum may fall short by dust — but must NEVER exceed it, which
    ///         would mean the derived views create value.
    function invariant_sumOfBalancesNeverExceedsTotalSupply() public view {
        address[3] memory actors = _actors();
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertLe(sum, token.totalSupply(), "sum of balances exceeded totalSupply");
    }

    /*//////////////////////////////////////////////////////////////
                             INVARIANT 5
    //////////////////////////////////////////////////////////////*/

    /// @notice registry.allocatedShares(token) == token.totalShares().
    ///         Backing reserved in the registry and shares issued by the token
    ///         stay exactly synchronized: every mint allocates and every redeem
    ///         releases the identical quantity, and nothing else touches either.
    ///         This is the property that makes the 1:1 primary path trustworthy.
    function invariant_registryBackingMatchesIssuedShares() public view {
        assertEq(
            registry.allocatedShares(address(token)),
            token.totalShares(),
            "registry backing desynchronized from issued shares"
        );
    }

    /// @dev Not an invariant -- a run summary, so we can confirm the fuzzer
    ///      exercised every action rather than silently skipping them.
    function invariant_callSummary() public view {
        console.log("--- handler call summary ---");
        console.log("mint                  :", handler.mintCalls());
        console.log("redeem                :", handler.redeemCalls());
        console.log("transfer              :", handler.transferCalls());
        console.log("transferShares        :", handler.transferSharesCalls());
        console.log("applyCorporateAction  :", handler.corporateActionCalls());
        console.log("skipped: no backing   :", handler.skippedNoBacking());
        console.log("skipped: no shares    :", handler.skippedNoShares());
        console.log("skipped: dust transfer:", handler.skippedDustTransfer());
        console.log("final multiplier      :", token.multiplier());
        console.log("final totalShares     :", token.totalShares());
    }
}
