// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRebasingEquityToken} from "../../src/interfaces/IRebasingEquityToken.sol";
import {ISettlementEngine} from "../../src/interfaces/ISettlementEngine.sol";
import {IVenueAdapter} from "../../src/interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../../src/libraries/OrderTypes.sol";

/// @title MockStable
/// @notice Plain, well-behaved 18-decimal ERC-20 standing in for the stable leg.
contract MockStable is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MisbehavingStable
/// @notice A stable that silently moves ONE WEI LESS than asked, leaving the
///         remainder with the sender, while still returning true.
/// @dev Models the class of non-conforming token the engine's assertions exist to
///      catch — fee-on-transfer, deflationary, or simply buggy. It returns `true`,
///      so `SafeERC20`'s return-value check passes and only a measured delta
///      reveals the shortfall.
///
///      Drives two distinct engine failures from one behaviour:
///        - on the INPUT leg the adapter is funded short  -> InputTransferMismatch
///        - on the OUTPUT leg the engine under-sends and
///          keeps the residue                             -> EngineRetainedFunds
contract MisbehavingStable is ERC20 {
    bool public short;

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setShort(bool v) external {
        short = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (short && from != address(0) && to != address(0) && value > 0) {
            super._update(from, to, value - 1);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @title ShortTransferEquity
/// @notice Minimal rebasing-token surface that moves one SHARE fewer than asked
///         on `transferSharesFrom`.
/// @dev Implements only what {SettlementEngine} actually calls, plus enough of
///      ERC-20 for the registration probe and the engine's balance snapshots.
///      Exists to reach the sell-leg {InputTransferMismatch} branch, which the
///      well-behaved token cannot produce because its share transfers are exact.
contract ShortTransferEquity {
    mapping(address => uint256) public shares;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalShares;
    uint256 public multiplier = 1e18;

    string public name = "ShortEquity";
    string public symbol = "SEQ";
    uint8 public decimals = 18;

    function mint(address to, uint256 shareAmount) external {
        shares[to] += shareAmount;
        totalShares += shareAmount;
    }

    function balanceOf(address a) external view returns (uint256) {
        return (shares[a] * multiplier) / 1e18;
    }

    function totalSupply() external view returns (uint256) {
        return (totalShares * multiplier) / 1e18;
    }

    function amountToShares(uint256 amount) external view returns (uint256) {
        return (amount * 1e18) / multiplier;
    }

    function sharesToAmount(uint256 shareAmount) external view returns (uint256) {
        return (shareAmount * multiplier) / 1e18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @dev THE MISBEHAVIOUR: one share short, and still reports success.
    function transferSharesFrom(address from, address to, uint256 shareAmount) external returns (bool) {
        uint256 moved = shareAmount > 0 ? shareAmount - 1 : 0;
        shares[from] -= moved;
        shares[to] += moved;
        return true;
    }

    function transferShares(address to, uint256 shareAmount) external returns (bool) {
        shares[msg.sender] -= shareAmount;
        shares[to] += shareAmount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 s = (amount * 1e18) / multiplier;
        shares[msg.sender] -= s;
        shares[to] += s;
        return true;
    }
}

/// @title MockZeroMultiplierToken
/// @notice Answers the registration probe but reports a zero multiplier.
/// @dev Exists to prove the probe checks the ANSWER, not merely that the call
///      succeeded. A contract can implement `multiplier()` and still be unusable.
contract MockZeroMultiplierToken {
    function multiplier() external pure returns (uint256) {
        return 0;
    }
}

/// @title MockAdapter
/// @notice Configurable venue adapter used to drive the settlement engine through
///         both correct and adversarial behaviour.
/// @dev PRE-FUND CONVENTION, which this mock honours in {Mode.Normal} and
///      deliberately violates in the other modes:
///        - it is funded BEFORE `swap` is called;
///        - it must execute EXACTLY `order.amountIn` from that funding;
///        - it must NOT touch any pre-existing holding.
///
///      The mock records what it was actually called with (`lastAmountIn`) and
///      what it held at entry (`sharesAtEntry`, `assetInBalanceAtEntry`) so tests
///      can assert on the engine's behaviour mid-flow rather than only on the
///      end state.
contract MockAdapter is IVenueAdapter {
    using SafeERC20 for IERC20;

    enum Mode {
        Normal,
        UnderReport,
        OverReport,
        RetainInput,
        Reverting,
        RebaseAttack,
        SweepAll
    }

    /// @dev Where consumed input goes. A real venue's pool; here just a hole.
    address public immutable sink;
    IRebasingEquityToken public immutable equity;

    Mode public mode = Mode.Normal;

    /// @dev Output token amount = amountIn * outputRateWad / 1e18.
    uint256 public outputRateWad = 1e18;

    /// @dev {Mode.RetainInput}: stable wei to keep on a buy, wei-SHARES on a sell.
    uint256 public retainAmount;

    /// @dev {Mode.RetainInput} on a sell: the adapter's share balance BEFORE the
    ///      settlement, so it can retain an exact quantity rather than a quantity
    ///      perturbed by its own rounding. Set by the test immediately before
    ///      submitting the order.
    uint256 public shareBaseline;

    /// @dev {Mode.RebaseAttack}: the multiplier to jump to mid-swap.
    uint256 public attackMultiplier;

    // ---- recorded for assertions ----
    uint256 public lastAmountIn;
    uint256 public sharesAtEntry;
    uint256 public assetInBalanceAtEntry;
    uint256 public swapCount;

    constructor(address sink_, IRebasingEquityToken equity_) {
        sink = sink_;
        equity = equity_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setOutputRate(uint256 rateWad) external {
        outputRateWad = rateWad;
    }

    function setRetainAmount(uint256 amount) external {
        retainAmount = amount;
    }

    function setShareBaseline(uint256 baseline) external {
        shareBaseline = baseline;
    }

    function setAttackMultiplier(uint256 m) external {
        attackMultiplier = m;
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * outputRateWad) / 1e18;
    }

    function swap(OrderTypes.Order calldata o, address recipient) external returns (uint256) {
        lastAmountIn = o.amountIn;
        sharesAtEntry = equity.shares(address(this));
        assetInBalanceAtEntry = IERC20(o.assetIn).balanceOf(address(this));
        ++swapCount;

        if (mode == Mode.Reverting) revert("MockAdapter: forced revert");

        // Fires before any transfer so the multiplier is already wrong for
        // everything that follows — the worst case for the engine's STEP 6 check.
        if (mode == Mode.RebaseAttack) equity.applyCorporateAction(attackMultiplier);

        uint256 amountOut = (o.amountIn * outputRateWad) / 1e18;

        if (o.assetOut == address(equity)) {
            _consumeStable(o.assetIn, o.amountIn);
            // Token-denominated on purpose: a real AMM pays out in token terms,
            // so the engine must derive the share delta itself.
            if (amountOut > 0) equity.transfer(recipient, amountOut);
        } else {
            _consumeEquity(o.amountIn);
            if (amountOut > 0) IERC20(o.assetOut).safeTransfer(recipient, amountOut);
        }

        // The engine discards this value for accounting. These two modes exist to
        // prove that it does.
        if (mode == Mode.UnderReport) return amountOut / 2;
        if (mode == Mode.OverReport) return amountOut * 2;
        return amountOut;
    }

    function _consumeStable(address assetIn, uint256 amountIn) private {
        uint256 spend = amountIn;
        if (mode == Mode.SweepAll) {
            spend = IERC20(assetIn).balanceOf(address(this));
        } else if (mode == Mode.RetainInput) {
            spend = amountIn > retainAmount ? amountIn - retainAmount : 0;
        }
        if (spend > 0) IERC20(assetIn).safeTransfer(sink, spend);
    }

    function _consumeEquity(uint256 amountIn) private {
        if (mode == Mode.SweepAll) {
            uint256 all = equity.shares(address(this));
            if (all > 0) equity.transferShares(sink, all);
            return;
        }

        if (mode == Mode.RetainInput) {
            // Share-exact so the retained quantity is exactly `retainAmount`, with
            // none of the flooring slack a token-denominated transfer would add.
            uint256 held = equity.shares(address(this));
            uint256 keep = shareBaseline + retainAmount;
            if (held > keep) equity.transferShares(sink, held - keep);
            return;
        }

        // Normal: spend the funded amount in TOKEN terms, exactly as a venue
        // would. This is what produces the legitimate 0-or-1 wei-share drift the
        // engine's sell-side retention check tolerates.
        if (equity.amountToShares(amountIn) > 0) equity.transfer(sink, amountIn);
    }
}

/// @title ReentrantRouterAdapter
/// @notice A contract that is BOTH a settlement engine's router and its adapter,
///         so it can re-enter `settle` from inside `swap` with `msg.sender`
///         already equal to the engine's router.
/// @dev WHY THIS SHAPE. In the production wiring the Router is itself
///      `nonReentrant`, so a re-entry attempt is stopped there and the ENGINE's
///      own guard is never reached — which would leave that guard untested. This
///      mock is initialized as the router of a dedicated engine instance so the
///      re-entrant call passes `onlyRouter` and lands on the engine's own
///      `nonReentrant`, proving the engine is safe independently of the Router.
contract ReentrantRouterAdapter is IVenueAdapter {
    ISettlementEngine public engine;
    bytes32 public venueId;
    OrderTypes.Order internal _order;

    function arm(ISettlementEngine engine_, OrderTypes.Order memory order_, bytes32 venueId_) external {
        engine = engine_;
        _order = order_;
        venueId = venueId_;
    }

    /// @notice Outer call: acts as the router.
    function trigger() external returns (uint256) {
        return engine.settle(_order, venueId, address(this));
    }

    function quote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @notice Inner call: acts as the adapter, re-entering the engine.
    function swap(OrderTypes.Order calldata, address) external returns (uint256) {
        engine.settle(_order, venueId, address(this));
        return 0;
    }
}
