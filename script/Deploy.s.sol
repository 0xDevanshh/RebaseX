// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Enum} from "safe-contracts/common/Enum.sol";
import {ModuleManager} from "safe-contracts/base/ModuleManager.sol";
import {Safe} from "safe-contracts/Safe.sol";
import {SafeProxyFactory} from "safe-contracts/proxies/SafeProxyFactory.sol";

import {TradingModule} from "../src/accounts/TradingModule.sol";
import {PancakeSwapAdapter} from "../src/adapters/PancakeSwapAdapter.sol";
import {Router} from "../src/core/Router.sol";
import {SettlementEngine} from "../src/core/SettlementEngine.sol";
import {ISettlementEngine} from "../src/interfaces/ISettlementEngine.sol";
import {IShareRegistry} from "../src/interfaces/IShareRegistry.sol";
import {MockRebasingEquityToken} from "../src/mocks/MockRebasingEquityToken.sol";
import {MockShareRegistry} from "../src/mocks/MockShareRegistry.sol";
import {MockStable} from "../src/mocks/MockStable.sol";
import {PrimaryReserveVault} from "../src/primary/PrimaryReserveVault.sol";
import {PrimaryVenueAdapter} from "../src/primary/PrimaryVenueAdapter.sol";
import {VenueRegistry} from "../src/router/VenueRegistry.sol";

/// @title Deploy
/// @notice Deploys the full RebaseX stack to BSC testnet (chain id 97) and wires
///         it end to end: token layer, both execution venues, settlement core,
///         a real Safe with {TradingModule} enabled, and enough demo funding
///         for a buy to actually execute afterward.
/// @dev ============ WHY THIS IS NOT `test/helpers/SafeDeployer.sol` ============
///      {SafeDeployer} is `abstract`, test-only by its own NatSpec, and reaches
///      the hevm cheatcode address directly
///      (`Vm(address(uint160(uint256(keccak256("hevm cheat code")))))`) to call
///      `VM.prank`/`VM.label`. That address is meaningful only inside Foundry's
///      test/script EVM — there is nothing there on a real chain. A forge
///      SCRIPT run with `--broadcast` sends genuine signed transactions, so
///      "the next call arrives from `owner`" has to be achieved by actually
///      being `owner`, not by asking the VM to pretend.
///
///      That turns out to need no cheatcode at all. Safe's own
///      `checkNSignatures` (`lib/safe-smart-account/contracts/Safe.sol`), for
///      the `v == 1` "approved hash" signature form:
///
///          } else if (v == 1) {
///              currentOwner = address(uint160(uint256(r)));
///              require(msg.sender == currentOwner
///                      || approvedHashes[currentOwner][dataHash] != 0, "GS025");
///
///      asks only whether `msg.sender` — the address that actually sent THIS
///      transaction — equals the owner encoded in `r`. In a real broadcast that
///      is not a simulation of anything: when this script calls
///      `safe.execTransaction(...)` while broadcasting as the deployer key, and
///      the deployer is the Safe's sole owner, `msg.sender` at the Safe IS that
///      owner, for the same reason it is in any other transaction anyone ever
///      sends. `{_execAsOwner}` below reproduces exactly the byte layout
///      {SafeDeployer._prevalidatedSignature} uses (`r = owner, s = 0, v = 1`)
///      because the ENCODING is not cheatcode-dependent — only `VM.prank` was.
///      Real ECDSA (`vm.sign` over the Safe transaction hash, recovered via
///      `v` in {27, 28}) would authenticate the exact same fact through a
///      different, heavier mechanism; Safe's own contract treats the two as
///      equally valid, and the pre-validated form is what production contract
///      owners and Safe's own `approveHash` flow actually use for a
///      self-submitted transaction. Chosen here for that reason, not as a
///      shortcut borrowed from a test helper.
///      ====================================================================
///
///      ============ WHY A CANONICAL SAFE, NOT A FRESH DEPLOYMENT ============
///      Confirmed ON-CHAIN against BSC testnet (via `cast code`, not merely
///      read from Safe's deployments repository) before hardcoding either
///      address below: both the Safe v1.4.1 singleton and its
///      `SafeProxyFactory` already hold real bytecode at their canonical,
///      cross-chain CREATE2 addresses on chain 97. Deploying fresh copies would
///      only add two more contracts to verify for no behavioural difference —
///      a proxy against the canonical singleton is indistinguishable from a
///      proxy against a freshly deployed one.
///      ====================================================================
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                                  NETWORK
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BSC_TESTNET_CHAIN_ID = 97;

    address internal constant PANCAKE_V2_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    /// @dev NOT called by this script. {PancakeSwapAdapter} is single-hop only
    ///      (see its NatSpec) and never queries the factory directly — the
    ///      router's `addLiquidity`/`getAmountsOut` are sufficient for every
    ///      call this system makes. Kept as a named constant purely so the
    ///      README's address table has it, since a reader wiring up a pool by
    ///      hand (outside this script) will want it.
    address internal constant PANCAKE_V2_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;

    /// @dev NOT used by this script, for the same reason as
    ///      {PANCAKE_V2_FACTORY}: single-hop only, no intermediate asset. Kept
    ///      as a named constant for README documentation only.
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    /// @dev Safe v1.4.1 canonical singleton, confirmed to hold code on BSC
    ///      testnet — see the contract-level NatSpec.
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;

    /// @dev Safe v1.4.1 canonical `SafeProxyFactory`, same confirmation.
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;

    /// @dev Fixed, not time- or block-derived. `createProxyWithNonce` uses this
    ///      purely as a CREATE2 salt component, so a fixed value is what makes
    ///      the Safe's address identical between a dry run and the real
    ///      broadcast — which is the whole point of reporting it during the
    ///      dry run before anything is sent.
    uint256 internal constant SAFE_SALT_NONCE = uint256(keccak256("rebasex-bsc-testnet-deploy-v1"));

    /*//////////////////////////////////////////////////////////////
                          ROLE / VENUE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Confirmed by re-reading test/PancakeSwapAdapter.t.sol,
    ///      test/fork/PancakeSwapSettlement.fork.t.sol, and test/VenueRegistry.t.sol
    ///      immediately before writing this script — unchanged from every
    ///      earlier diagnostic.
    bytes32 internal constant PANCAKE_VENUE_ID = keccak256("PANCAKE_V2");

    /// @dev Confirmed by re-reading test/PrimaryVenueAdapter.t.sol's
    ///      `PrimaryAdapterFixture` immediately before writing this script —
    ///      unchanged from every earlier diagnostic.
    bytes32 internal constant PRIMARY_VENUE_ID = keccak256("PRIMARY_VENUE");

    /*//////////////////////////////////////////////////////////////
                                  AMOUNTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Generous headroom for `MockShareRegistry.setCustodiedShares`, so
    ///      later demo mints never fail on backing availability for a reason
    ///      unrelated to whatever is actually being demonstrated.
    uint256 internal constant INITIAL_CUSTODIED_SHARES = 10_000_000e18;

    /// @dev `TradingModule.setEngineShareCap` — the most equity-shares the Safe
    ///      will ever let {SettlementEngine} hold permission over.
    uint256 internal constant SHARE_CAP = 1_000_000e18;

    /// @dev `TradingModule.setEngineTokenAllowance` — the Safe's stable ERC-20
    ///      allowance to {SettlementEngine}.
    uint256 internal constant STABLE_ALLOWANCE = 1_000_000e18;

    /// @dev `TradingModule.setEngineShareAllowance` — the Safe's initial
    ///      approveShares grant, so a demo sell can execute without a separate
    ///      operator transaction first.
    uint256 internal constant SHARE_ALLOWANCE = 1_000_000e18;

    /// @dev Minted to `admin`, then split between the vault seed and whatever
    ///      remains for further admin-side demos.
    uint256 internal constant INITIAL_STABLE_SUPPLY = 1_000_000e18;

    /// @dev `PrimaryReserveVault.adminDeposit` — reserve backing primary-market
    ///      redemptions.
    uint256 internal constant VAULT_SEED_AMOUNT = 500_000e18;

    /// @dev Stable minted directly to the Safe so a demo buy has something to
    ///      spend without a separate funding transaction.
    uint256 internal constant CLIENT_STABLE_FUNDING = 10_000e18;

    /*//////////////////////////////////////////////////////////////
                              RESULT STRUCT
    //////////////////////////////////////////////////////////////*/

    /// @dev A SINGLE memory struct threaded through every step, instead of the
    ///      dozen-plus separate typed locals `run()` would otherwise have to
    ///      hold at once — legacy (non-IR) codegen hit "stack too deep" with
    ///      that many live locals in one function, and enabling `via-ir`
    ///      globally would touch every other contract's build for a problem
    ///      local to this one script. A memory struct passed to each `private`
    ///      helper is passed BY REFERENCE, so a helper writing `d.engine = ...`
    ///      is visible to `run()` and to every later helper without `run()`
    ///      ever declaring `engine` as its own local.
    struct Deployment {
        address admin;
        address feeRecipient;
        address operator;
        address registry;
        address stable;
        address equity;
        address venues;
        address pancakeAdapter;
        address vault;
        address primaryAdapter;
        address engine;
        address router;
        address safe;
        address module;
    }

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        require(block.chainid == BSC_TESTNET_CHAIN_ID, "Deploy: not BSC testnet (chain id 97)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        Deployment memory d;
        d.admin = vm.addr(deployerKey);

        d.feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));
        if (d.feeRecipient == address(0)) {
            d.feeRecipient = d.admin;
            console2.log("WARNING: FEE_RECIPIENT not set - defaulting to admin.");
            console2.log("  Fee revenue and admin control are co-located. Testnet simplification only.");
        }

        d.operator = vm.envOr("OPERATOR_ADDRESS", address(0));
        if (d.operator == address(0)) {
            d.operator = d.admin;
            console2.log("WARNING: OPERATOR_ADDRESS not set - defaulting to admin.");
            console2.log("  Owner and operator share one key. Testnet convenience only.");
        }

        console2.log("Deployer / admin:", d.admin);
        console2.log("Fee recipient:   ", d.feeRecipient);
        console2.log("Operator:        ", d.operator);

        vm.startBroadcast(deployerKey);

        _deployTokenLayer(d);
        _deployVenueLayer(d);
        _deployEngineLayer(d);
        _wireEngineAndVenues(d);
        _deploySafeStack(d);
        _configureModule(d);
        _fundDemoAccounts(d);

        vm.stopBroadcast();

        _writeDeploymentSummary(d);
    }

    /*//////////////////////////////////////////////////////////////
                          STEPS 1-6: TOKEN LAYER
    //////////////////////////////////////////////////////////////*/

    function _deployTokenLayer(Deployment memory d) private {
        MockShareRegistry registry = new MockShareRegistry(d.admin);
        console2.log("MockShareRegistry:      ", address(registry));
        d.registry = address(registry);

        MockStable stable = new MockStable("Mock USD", "mUSD", 18);
        console2.log("MockStable:              ", address(stable));
        d.stable = address(stable);

        MockRebasingEquityToken equity =
            new MockRebasingEquityToken("Mock Equity", "mEQ", d.admin, IShareRegistry(address(registry)));
        console2.log("MockRebasingEquityToken: ", address(equity));
        d.equity = address(equity);

        registry.registerToken(address(equity));
        registry.setCustodiedShares(address(equity), INITIAL_CUSTODIED_SHARES);

        equity.grantRole(equity.PRIMARY_ROLE(), d.admin);
        equity.grantRole(equity.CORPORATE_ACTION_ROLE(), d.admin);
    }

    /*//////////////////////////////////////////////////////////////
                    STEPS 7-12: VENUES + PRIMARY MARKET
    //////////////////////////////////////////////////////////////*/

    function _deployVenueLayer(Deployment memory d) private {
        VenueRegistry venues = new VenueRegistry(d.admin);
        console2.log("VenueRegistry:           ", address(venues));
        d.venues = address(venues);

        PancakeSwapAdapter pancakeAdapter = new PancakeSwapAdapter(PANCAKE_V2_ROUTER);
        console2.log("PancakeSwapAdapter:      ", address(pancakeAdapter));
        d.pancakeAdapter = address(pancakeAdapter);

        // The vault deploys standalone first: it takes no adapter address, so
        // there is no circular dependency to break — matching
        // {test/PrimaryVenueAdapter.t.sol}'s `_deployAndWire`.
        PrimaryReserveVault vault = new PrimaryReserveVault(IERC20(d.stable), d.admin);
        console2.log("PrimaryReserveVault:     ", address(vault));
        d.vault = address(vault);

        PrimaryVenueAdapter primaryAdapter = new PrimaryVenueAdapter(d.equity, d.stable, address(vault));
        console2.log("PrimaryVenueAdapter:     ", address(primaryAdapter));
        d.primaryAdapter = address(primaryAdapter);

        MockRebasingEquityToken equity = MockRebasingEquityToken(d.equity);
        equity.grantRole(equity.PRIMARY_ROLE(), address(primaryAdapter));
        vault.grantRole(vault.ADAPTER_ROLE(), address(primaryAdapter));
    }

    /*//////////////////////////////////////////////////////////////
                       STEPS 13-14: ENGINE + ROUTER
    //////////////////////////////////////////////////////////////*/

    function _deployEngineLayer(Deployment memory d) private {
        SettlementEngine engine = new SettlementEngine(d.admin, VenueRegistry(d.venues), d.feeRecipient);
        console2.log("SettlementEngine:        ", address(engine));
        d.engine = address(engine);

        Router router = new Router(VenueRegistry(d.venues), ISettlementEngine(address(engine)));
        console2.log("Router:                  ", address(router));
        d.router = address(router);
    }

    /*//////////////////////////////////////////////////////////////
              STEPS 15-17: CLOSE THE CIRCULAR DEPENDENCY,
                      REGISTER THE TOKEN AND BOTH VENUES
    //////////////////////////////////////////////////////////////*/

    function _wireEngineAndVenues(Deployment memory d) private {
        SettlementEngine engine = SettlementEngine(d.engine);

        engine.initializeRouter(d.router);
        // Not a state-changing call left unverified: this is the one write
        // that can never be repeated (`RouterAlreadyInitialized` on a second
        // attempt), so confirming it actually took effect belongs here, not in
        // a later step where a silent no-op would surface as a confusing
        // failure far from its cause.
        require(engine.router() == d.router, "Deploy: initializeRouter did not take effect");
        console2.log("Confirmed: engine.router() ==", engine.router());

        engine.registerRebasingToken(d.equity, true);

        // Single admin call each - no propose/commit timelock exists on
        // {VenueRegistry}, confirmed by inspection of its actual source.
        VenueRegistry venues = VenueRegistry(d.venues);
        venues.setAdapter(PANCAKE_VENUE_ID, d.pancakeAdapter);
        venues.setAdapter(PRIMARY_VENUE_ID, d.primaryAdapter);
    }

    /*//////////////////////////////////////////////////////////////
                  STEPS 18-19: SAFE + TRADINGMODULE
    //////////////////////////////////////////////////////////////*/

    function _deploySafeStack(Deployment memory d) private {
        address[] memory owners = new address[](1);
        owners[0] = d.admin;

        bytes memory initializer = abi.encodeCall(
            Safe.setup,
            (
                owners,
                1, // threshold
                address(0), // to: no setup delegatecall
                "", // data
                address(0), // fallbackHandler
                address(0), // paymentToken
                0, // payment
                payable(address(0)) // paymentReceiver
            )
        );

        address safe = address(
            SafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, initializer, SAFE_SALT_NONCE)
        );
        console2.log("Safe:                    ", safe);
        d.safe = safe;

        TradingModule module = new TradingModule(safe, d.router);
        console2.log("TradingModule:           ", address(module));
        d.module = address(module);

        _execAsOwner(safe, safe, abi.encodeCall(ModuleManager.enableModule, (address(module))), d.admin);
    }

    /*//////////////////////////////////////////////////////////////
                       STEP 21: CONFIGURE THE MODULE
    //////////////////////////////////////////////////////////////*/

    function _configureModule(Deployment memory d) private {
        _execAsOwner(d.safe, d.module, abi.encodeCall(TradingModule.setApprovedEngine, (d.engine, true)), d.admin);
        _execAsOwner(
            d.safe, d.module, abi.encodeCall(TradingModule.setEngineShareCap, (d.engine, d.equity, SHARE_CAP)), d.admin
        );
        _execAsOwner(
            d.safe,
            d.module,
            abi.encodeCall(TradingModule.setEngineTokenAllowance, (d.engine, d.stable, STABLE_ALLOWANCE)),
            d.admin
        );
        _execAsOwner(d.safe, d.module, abi.encodeCall(TradingModule.setOperator, (d.operator, true)), d.admin);

        // {setEngineShareAllowance} is `onlyOperatorOrSafe`, not `onlySafe` -
        // callable directly by the operator without a Safe transaction. The
        // operator IS the deployer here unless `OPERATOR_ADDRESS` overrides it,
        // and only the deployer's key is broadcasting, so this call is made
        // directly rather than routed through `_execAsOwner`.
        if (d.operator == d.admin) {
            TradingModule(d.module).setEngineShareAllowance(d.engine, d.equity, SHARE_ALLOWANCE);
        } else {
            console2.log("NOTE: OPERATOR_ADDRESS differs from the deployer key.");
            console2.log("  setEngineShareAllowance was NOT called - only the operator key can call it.");
            console2.log("  Run it once from the operator's own key before demoing a sell.");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    STEPS 22-24: DEMO FUNDING
    //////////////////////////////////////////////////////////////*/

    function _fundDemoAccounts(Deployment memory d) private {
        MockStable stable = MockStable(d.stable);
        stable.mint(d.admin, INITIAL_STABLE_SUPPLY);

        stable.approve(d.vault, VAULT_SEED_AMOUNT);
        PrimaryReserveVault vault = PrimaryReserveVault(d.vault);
        vault.adminDeposit(VAULT_SEED_AMOUNT);
        console2.log("Vault reserve seeded:    ", vault.reserveBalance());

        stable.mint(d.safe, CLIENT_STABLE_FUNDING);
    }

    /*//////////////////////////////////////////////////////////////
                        SAFE OWNER TRANSACTION HELPER
    //////////////////////////////////////////////////////////////*/

    /// @dev Reproduces {SafeDeployer.execAsOwner}'s call shape exactly, with
    ///      `owner`'s signature built inline rather than via
    ///      {SafeDeployer._prevalidatedSignature} - that helper is `internal`
    ///      on an abstract, test-only contract this script does not, and
    ///      should not, inherit. The encoding itself is pure byte layout, not a
    ///      cheatcode: `r = owner, s = 0, v = 1`, Safe's documented
    ///      "approved hash" form. See the contract-level NatSpec for why this
    ///      is valid on a REAL broadcast, not merely inside a test VM.
    function _execAsOwner(address safe, address to, bytes memory data, address owner) private {
        bytes memory signature = abi.encodePacked(
            bytes32(uint256(uint160(owner))), // r = owner
            bytes32(0), // s = unused
            uint8(1) // v = 1 -> pre-validated / approved-hash form
        );

        (bool ok, bytes memory ret) = safe.call(
            abi.encodeCall(
                Safe.execTransaction,
                (
                    to,
                    0, // value
                    data,
                    Enum.Operation.Call,
                    0, // safeTxGas - zero puts Safe in revert-on-inner-failure mode
                    0, // baseGas
                    0, // gasPrice - zero, so no refund logic runs
                    address(0), // gasToken
                    payable(address(0)), // refundReceiver
                    signature
                )
            )
        );

        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOYMENT SUMMARY OUTPUT
    //////////////////////////////////////////////////////////////*/

    /// @dev Split into several smaller `string.concat` calls rather than one
    ///      giant one for the same reason {run} was split across helpers:
    ///      `string.concat` with ~35 simultaneous arguments hit the same
    ///      "stack too deep" wall legacy codegen hit on {run}'s locals. Each
    ///      piece below stays well under it.
    function _writeDeploymentSummary(Deployment memory d) private {
        string memory header = string.concat(
            "{\n",
            '  "network": "bsc-testnet",\n',
            '  "chainId": 97,\n',
            '  "admin": "',
            vm.toString(d.admin),
            '",\n',
            '  "feeRecipient": "',
            vm.toString(d.feeRecipient),
            '",\n',
            '  "operator": "',
            vm.toString(d.operator),
            '",\n',
            '  "contracts": {\n'
        );

        string memory contractsA = string.concat(
            _entry(
                "MockShareRegistry", d.registry, "Records underlying share units backing the mock equity token", true
            ),
            _entry("MockStable", d.stable, "Mock 18-decimal stablecoin (mUSD), permissionless mint", true),
            _entry(
                "MockRebasingEquityToken", d.equity, "Rebasing tokenised equity (mEQ), share-denominated balances", true
            ),
            _entry("VenueRegistry", d.venues, "Maps a venueId to its adapter address", true),
            _entry(
                "PancakeSwapAdapter",
                d.pancakeAdapter,
                "AMM execution venue against the real PancakeSwap V2 router",
                true
            )
        );

        string memory contractsB = string.concat(
            _entry("PrimaryReserveVault", d.vault, "Holds the stable reserve backing primary-market redemptions", true),
            _entry(
                "PrimaryVenueAdapter", d.primaryAdapter, "Primary market: mints/redeems the equity token at par", true
            ),
            _entry(
                "SettlementEngine", d.engine, "Executes settlement: pulls funds, calls the venue, applies the fee", true
            ),
            _entry("Router", d.router, "Resolves a venueId (or runs best execution) and calls SettlementEngine", true),
            _entry(
                "TradingModule", d.module, "Safe module granting scoped, capped trading authority to an operator", false
            )
        );

        string memory footer = string.concat(
            "  },\n",
            '  "venues": {\n',
            '    "PANCAKE_V2": "',
            vm.toString(PANCAKE_VENUE_ID),
            '",\n',
            '    "PRIMARY_VENUE": "',
            vm.toString(PRIMARY_VENUE_ID),
            '"\n',
            "  },\n",
            '  "safe": "',
            vm.toString(d.safe),
            '",\n',
            '  "tradingModule": "',
            vm.toString(d.module),
            '"\n',
            "}\n"
        );

        string memory json = string.concat(header, contractsA, contractsB, footer);

        vm.writeFile("deployments/bsc-testnet.json", json);
        console2.log("Deployment summary written to deployments/bsc-testnet.json");
    }

    function _entry(string memory name, address addr, string memory role, bool trailingComma)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '    "',
            name,
            '": { "address": "',
            _addrString(addr),
            '", "role": "',
            role,
            '" }',
            trailingComma ? ",\n" : "\n"
        );
    }

    /// @dev `vm.toString` is declared `pure` on the `Vm` interface, so calling
    ///      it from this `pure` helper compiles - this wrapper exists only to
    ///      keep {_entry} free of importing `Vm` directly.
    function _addrString(address addr) private pure returns (string memory) {
        return vm.toString(addr);
    }
}
