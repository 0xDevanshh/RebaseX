// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStable
/// @notice Plain, well-behaved ERC-20 standing in for the stable leg, deployable
///         to a real testnet — not test-only.
/// @dev LIVES IN `src/`, NOT `test/`, because a deployment script needs it: this
///      system has no production stablecoin of its own (`PrimaryReserveVault`
///      and `PrimaryVenueAdapter` take whatever stable address they are handed),
///      and a testnet deployment needs something to hand them. `script/` is
///      production code that runs against a real chain, so what it imports must
///      live in `src/`, not in a test-only file that a deploy script has no
///      business depending on.
///
///      MINT IS DELIBERATELY PERMISSIONLESS. This is a mock stablecoin for a
///      testnet deployment/demo, not a production asset — there is no peg to
///      protect and no holder whose balance an open `mint` could devalue in any
///      way that matters. Restricting it to a role would only add a grant this
///      project's deploy and demo scripts would have to thread through for no
///      security benefit in this context: anyone testing against this
///      deployment can already mint themselves stable and it costs nothing to
///      let them do so directly.
///
///      DECIMALS ARE EXPLICIT, NOT HARDCODED. `PrimaryReserveVault` and
///      `PrimaryVenueAdapter` both do their arithmetic assuming the stable and
///      the rebasing equity token share the SAME 1e18 scale as each other — see
///      `PrimaryVenueAdapter.quote`, which combines the two directly with no
///      decimals conversion anywhere. Taking `decimals_` as a constructor
///      argument documents that shared-scale assumption at the one place it
///      could silently break, rather than baking `18` into the contract where a
///      future deployment could change it without anyone noticing the
///      assumption it was relying on.
contract MockStable is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` of this stable to `to`. Callable by anyone — see
    ///         the contract-level NatSpec for why that is deliberate here.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
