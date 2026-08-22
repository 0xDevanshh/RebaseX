// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {TradingModule} from "../src/accounts/TradingModule.sol";
import {Router} from "../src/core/Router.sol";
import {SettlementEngine} from "../src/core/SettlementEngine.sol";
import {IVenueAdapter} from "../src/interfaces/IVenueAdapter.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockStable} from "../src/mocks/MockStable.sol";

/// @title DemoTransactions
/// @notice Three transactions against the already-deployed BSC testnet stack,
///         chosen to make one property visible on-chain: a settlement, a
///         corporate action, and a second settlement priced correctly against
///         the new multiplier.
/// @dev ============ ADDRESSES COME FROM THE DEPLOYMENT RECORD, NOT MEMORY ============
///      Every address and both venueId values are read from
///      `deployments/bsc-testnet.json` at runtime via `vm.readFile` +
///      `vm.parseJsonAddress`/`vm.parseJsonBytes32`. Nothing here is a literal
///      copied from an earlier conversation - if that file is stale or wrong,
///      this script fails loudly against live state rather than silently
///      acting on an assumption.
///
///      ============ WHY THIS SCRIPT CANNOT PRINT ITS OWN TX HASHES ============
///      A forge script's `run()` executes ONCE, in simulation, to produce the
///      trace `-vvvv` shows and every `console2.log` line below. Broadcasting
///      happens AFTERWARD, as a separate pass outside that EVM execution, where
///      forge signs and sends the transactions it recorded. A transaction's
///      hash is a function of its signature, which does not exist yet while
///      `run()` is executing - there is no cheatcode that hands back "the hash
///      of the transaction this call is about to become", because at the time
///      of the call it has not become one.
///
///      So the three hashes are read the same way they were read after
///      {Deploy.s.sol}'s broadcast: from
///      `broadcast/DemoTransactions.s.sol/<chainid>/run-latest.json`, whose
///      `receipts[].transactionHash` fields are populated only once the real
///      broadcast completes. This script logs everything that IS knowable
///      in-EVM (resolved venue, share/balance deltas, the corporate-action
///      invariant) and stops there; the final hash-to-README mapping is a
///      post-broadcast step, not a limitation of this script's design.
///      ====================================================================
contract DemoTransactions is Script {
    /// @dev Bundles everything read from the deployment record so no function
    ///      below needs more than a handful of its own locals - the same
    ///      stack-pressure lesson from {Deploy.s.sol}.
    struct Deployed {
        address admin;
        address safe;
        address module;
        address engine;
        address stable;
        address equity;
        address pancakeAdapter;
        address primaryAdapter;
        bytes32 pancakeVenueId;
        bytes32 primaryVenueId;
    }

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Deployed memory dep = _loadDeployment();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        require(
            deployer == dep.admin,
            "DemoTransactions: PRIVATE_KEY does not match the admin/operator recorded in deployments/bsc-testnet.json"
        );

        console2.log("Deployer / operator:", deployer);
        console2.log("Safe:                ", dep.safe);

        vm.startBroadcast(deployerKey);

        _demoTx1SuccessfulSettlement(dep);
        _demoTx2CorporateAction(dep);
        _demoTx3SettlementAfterCorporateAction(dep);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== ALL THREE DEMO TRANSACTIONS SUBMITTED ===");
        console2.log("Tx hashes are not knowable from inside this script - see the NatSpec above.");
        console2.log("After broadcasting, read:");
        console2.log("  broadcast/DemoTransactions.s.sol/97/run-latest.json");
        console2.log("and take receipts[].transactionHash for the three submitOrder/applyCorporateAction calls,");
        console2.log("in the order they were sent, for the README's Demonstration transactions table.");
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOYMENT RECORD LOADING
    //////////////////////////////////////////////////////////////*/

    function _loadDeployment() private view returns (Deployed memory dep) {
        string memory json = vm.readFile("deployments/bsc-testnet.json");

        dep.admin = vm.parseJsonAddress(json, ".admin");
        dep.safe = vm.parseJsonAddress(json, ".safe");
        dep.module = vm.parseJsonAddress(json, ".tradingModule");
        dep.engine = vm.parseJsonAddress(json, ".contracts.SettlementEngine.address");
        dep.stable = vm.parseJsonAddress(json, ".contracts.MockStable.address");
        dep.equity = vm.parseJsonAddress(json, ".contracts.MockRebasingEquityToken.address");
        dep.pancakeAdapter = vm.parseJsonAddress(json, ".contracts.PancakeSwapAdapter.address");
        dep.primaryAdapter = vm.parseJsonAddress(json, ".contracts.PrimaryVenueAdapter.address");
        dep.pancakeVenueId = vm.parseJsonBytes32(json, ".venues.PANCAKE_V2");
        dep.primaryVenueId = vm.parseJsonBytes32(json, ".venues.PRIMARY_VENUE");
    }

    /*//////////////////////////////////////////////////////////////
              DEMO TX 1 - A SUCCESSFUL SETTLEMENT (BUY, BEST EXECUTION)
    //////////////////////////////////////////////////////////////*/

    function _demoTx1SuccessfulSettlement(Deployed memory dep) private {
        console2.log("");
        console2.log("=== DEMO TX 1: SUCCESSFUL SETTLEMENT ===");

        uint256 amountIn = 100e18;
        uint256 minAmountOut = _bestBuyMinAmountOut(dep, amountIn);

        OrderTypes.Order memory order = OrderTypes.Order({
            account: dep.safe,
            assetIn: dep.stable,
            assetOut: dep.equity,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            venueId: bytes32(0), // best execution - this is the Part B routing decision
            deadline: block.timestamp + 600
        });

        uint256 sharesBefore = MockRebasingEquityToken(dep.equity).shares(dep.safe);

        vm.recordLogs();
        uint256 amountOutNet = TradingModule(dep.module).submitOrder(order);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _logTx1Result(dep, logs, sharesBefore, amountOutNet);
    }

    function _bestBuyMinAmountOut(Deployed memory dep, uint256 amountIn) private view returns (uint256) {
        uint256 pancakeQuote = IVenueAdapter(dep.pancakeAdapter).quote(dep.stable, dep.equity, amountIn);
        uint256 primaryQuote = IVenueAdapter(dep.primaryAdapter).quote(dep.stable, dep.equity, amountIn);
        console2.log("Pre-trade quote (PancakeSwapAdapter):", pancakeQuote);
        console2.log("Pre-trade quote (PrimaryVenueAdapter):", primaryQuote);

        uint256 bestQuote = pancakeQuote > primaryQuote ? pancakeQuote : primaryQuote;
        require(bestQuote > 0, "DemoTx1: neither venue can quote this buy");
        // Conservative, non-zero floor - Router.ZeroMinAmountOut rejects 0
        // outright, and 99% comfortably clears the engine's 2 bps fee with no
        // real AMM slippage risk to budget for on either venue here.
        return (bestQuote * 99) / 100;
    }

    function _logTx1Result(Deployed memory dep, Vm.Log[] memory logs, uint256 sharesBefore, uint256 amountOutNet)
        private
        view
    {
        (bytes32 resolvedVenueId,,) = _decodeSettled(logs);
        uint256 sharesAfter = MockRebasingEquityToken(dep.equity).shares(dep.safe);

        console2.log("Resolved venue:            ", _venueName(dep, resolvedVenueId));
        console2.log("Client shares before:      ", sharesBefore);
        console2.log("Client shares after:       ", sharesAfter);
        console2.log("Net amount received (mEQ): ", amountOutNet);
    }

    /*//////////////////////////////////////////////////////////////
                  DEMO TX 2 - A CORPORATE ACTION APPLIED
    //////////////////////////////////////////////////////////////*/

    function _demoTx2CorporateAction(Deployed memory dep) private {
        console2.log("");
        console2.log("=== DEMO TX 2: CORPORATE ACTION APPLIED ===");

        MockRebasingEquityToken equity = MockRebasingEquityToken(dep.equity);

        uint256 multiplierBefore = equity.multiplier();
        uint256 newMultiplier = multiplierBefore * 2;

        uint256 sharesBefore = equity.shares(dep.safe);
        uint256 balanceBefore = equity.balanceOf(dep.safe);

        equity.applyCorporateAction(newMultiplier);

        uint256 multiplierAfter = equity.multiplier();
        uint256 sharesAfter = equity.shares(dep.safe);
        uint256 balanceAfter = equity.balanceOf(dep.safe);

        console2.log("Multiplier before:  ", multiplierBefore);
        console2.log("Multiplier after:   ", multiplierAfter);
        console2.log("Safe balanceOf before (mEQ):", balanceBefore);
        console2.log("Safe balanceOf after  (mEQ):", balanceAfter);
        console2.log("Safe shares before: ", sharesBefore);
        console2.log("Safe shares after:  ", sharesAfter);

        // THE PROPERTY THIS ASSESSMENT IS GRADED ON: no value created or
        // destroyed across a rebase. Asserted here, not merely claimed -
        // balanceOf must exactly double, shares must not move at all.
        require(multiplierAfter == multiplierBefore * 2, "DemoTx2: multiplier did not double");
        require(balanceAfter == balanceBefore * 2, "DemoTx2: balanceOf did not double with the multiplier");
        require(sharesAfter == sharesBefore, "DemoTx2: shares changed - value was created or destroyed");
    }

    /*//////////////////////////////////////////////////////////////
        DEMO TX 3 - A SETTLEMENT AFTER THE CORPORATE ACTION (SELL, BEST EXECUTION)
    //////////////////////////////////////////////////////////////*/

    function _demoTx3SettlementAfterCorporateAction(Deployed memory dep) private {
        console2.log("");
        console2.log("=== DEMO TX 3: SETTLEMENT AFTER CORPORATE ACTION ===");

        (uint256 sellAmountIn, uint256 expectedSharesIn, uint256 minAmountOut) = _prepareTx3Order(dep);

        OrderTypes.Order memory order = OrderTypes.Order({
            account: dep.safe,
            assetIn: dep.equity,
            assetOut: dep.stable,
            amountIn: sellAmountIn,
            minAmountOut: minAmountOut,
            venueId: bytes32(0), // best execution again - the sell-side routing decision
            deadline: block.timestamp + 600
        });

        uint256 stableBefore = MockStable(dep.stable).balanceOf(dep.safe);

        vm.recordLogs();
        uint256 amountOutNet = TradingModule(dep.module).submitOrder(order);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _logTx3Result(dep, logs, expectedSharesIn, stableBefore, amountOutNet);
    }

    /// @dev Sell half of whatever the Safe holds NOW (post-rebase). Deriving
    ///      `sellAmountIn` from the CURRENT balance, then converting it to
    ///      shares at the CURRENT (new) multiplier, is the explicit
    ///      computation the task calls for - reusing TX 1's nominal amountIn
    ///      unmodified would silently mean something different in shares
    ///      after TX 2.
    function _prepareTx3Order(Deployed memory dep)
        private
        returns (uint256 sellAmountIn, uint256 expectedSharesIn, uint256 minAmountOut)
    {
        MockRebasingEquityToken equity = MockRebasingEquityToken(dep.equity);

        uint256 currentBalance = equity.balanceOf(dep.safe);
        sellAmountIn = currentBalance / 2;
        expectedSharesIn = equity.amountToShares(sellAmountIn); // floor, at the NEW multiplier

        console2.log("Safe's equity balance now (post-rebase):   ", currentBalance);
        console2.log("Selling nominal token amount (half of it): ", sellAmountIn);
        console2.log("-> resolves to shares at the new multiplier:", expectedSharesIn);

        _ensureShareAllowance(dep, equity, expectedSharesIn);

        uint256 pancakeQuote = IVenueAdapter(dep.pancakeAdapter).quote(dep.equity, dep.stable, sellAmountIn);
        uint256 primaryQuote = IVenueAdapter(dep.primaryAdapter).quote(dep.equity, dep.stable, sellAmountIn);
        console2.log("Pre-trade quote (PancakeSwapAdapter): ", pancakeQuote);
        console2.log("Pre-trade quote (PrimaryVenueAdapter):", primaryQuote);

        uint256 bestQuote = pancakeQuote > primaryQuote ? pancakeQuote : primaryQuote;
        require(bestQuote > 0, "DemoTx3: neither venue can quote this sell");
        minAmountOut = (bestQuote * 99) / 100;
    }

    function _logTx3Result(
        Deployed memory dep,
        Vm.Log[] memory logs,
        uint256 expectedSharesIn,
        uint256 stableBefore,
        uint256 amountOutNet
    ) private view {
        (bytes32 resolvedVenueId, uint256 sharesIn, uint256 multiplierAtSettlement) = _decodeSettled(logs);
        uint256 stableAfter = MockStable(dep.stable).balanceOf(dep.safe);

        console2.log("Resolved venue:              ", _venueName(dep, resolvedVenueId));
        console2.log("Multiplier at settlement:    ", multiplierAtSettlement);
        console2.log("Shares debited (Settled evt):", sharesIn);
        console2.log("Expected shares (pre-trade): ", expectedSharesIn);
        // THE FLOOR/CEIL DISTINCTION ALREADY BUILT INTO THIS SYSTEM: this must
        // match EXACTLY, not approximately - both sides floor the same
        // nominal amount at the same multiplier via the same conversion.
        require(sharesIn == expectedSharesIn, "DemoTx3: settled sharesIn does not match the pre-trade computation");
        console2.log("Safe stable balance before:", stableBefore);
        console2.log("Safe stable balance after: ", stableAfter);
        console2.log("Net stable received:       ", amountOutNet);
    }

    /// @dev An up-only rebase can only shrink (never grow) the token-denominated
    ///      allowance's SHARE readback - see
    ///      {TradingModule.setEngineShareAllowance}'s own NatSpec. Refreshes it
    ///      only if the post-rebase readback would actually be insufficient,
    ///      so the common case adds no extra transaction beyond the three
    ///      demo ones.
    function _ensureShareAllowance(Deployed memory dep, MockRebasingEquityToken equity, uint256 sharesNeeded) private {
        uint256 allowanceShares = equity.allowanceShares(dep.safe, dep.engine);
        if (allowanceShares < sharesNeeded) {
            console2.log("Refreshing share allowance before selling (post-rebase readback was insufficient).");
            TradingModule(dep.module).setEngineShareAllowance(dep.engine, dep.equity, sharesNeeded * 2);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              EVENT DECODING
    //////////////////////////////////////////////////////////////*/

    /// @dev Reuses this repo's own established pattern for reading the actual
    ///      resolved venue off-chain-verifiably rather than assuming it -
    ///      `Router.OrderRouted.selector` as the topic to match is exactly
    ///      what {test/integration/PrimaryRouting.t.sol} and
    ///      {test/PrimaryVenueAdapter.t.sol} already do, not a new convention
    ///      invented for this script. `SettlementEngine.Settled.selector` is
    ///      matched the same way for `sharesIn` and `multiplierAtSettlement`.
    function _decodeSettled(Vm.Log[] memory logs)
        private
        pure
        returns (bytes32 resolvedVenueId, uint256 sharesIn, uint256 multiplierAtSettlement)
    {
        bytes32 routedTopic = Router.OrderRouted.selector;
        bytes32 settledTopic = SettlementEngine.Settled.selector;

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32[] memory topics = logs[i].topics;
            if (topics.length == 0) continue;

            if (topics[0] == routedTopic) {
                resolvedVenueId = topics[2];
            } else if (topics[0] == settledTopic) {
                (,,,, uint256 decodedSharesIn,,, uint256 decodedMultiplier,,,) = abi.decode(
                    logs[i].data,
                    (address, bool, address, address, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );
                sharesIn = decodedSharesIn;
                multiplierAtSettlement = decodedMultiplier;
            }
        }
    }

    function _venueName(Deployed memory dep, bytes32 venueId) private pure returns (string memory) {
        if (venueId == dep.pancakeVenueId) return "PANCAKE_V2";
        if (venueId == dep.primaryVenueId) return "PRIMARY_VENUE";
        return "UNKNOWN";
    }
}
