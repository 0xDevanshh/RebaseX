## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## Attribution

Third-party code used in this project. All dependencies are pinned to a tag (not
a branch) and the resolved commits are recorded in `foundry.lock`.

| Dependency | Version | Commit | License | Used for |
| --- | --- | --- | --- | --- |
| [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) | `v1.16.2` | `bf647bd` | MIT | Test framework and cheatcodes (test-only) |
| [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | `v5.7.0` | `cab1993` | MIT | `ERC20`, `SafeERC20`, `Ownable`, `ReentrancyGuard` |
| [safe-global/safe-smart-account](https://github.com/safe-global/safe-smart-account) | `v1.4.1` | `bf943f8` | LGPL-3.0-only | Client smart account (A5): `Safe`, `SafeProxyFactory`, `ModuleManager` |

### Why Safe v1.4.1

`v1.4.1` rather than the newer `v1.5.0`: v1.4.1 is the release whose singleton and
`SafeProxyFactory` are deployed at canonical addresses on BSC, the chain the
PancakeSwap fork test runs against. A module written against v1.4.1 therefore
works with Safes that exist today, rather than with a version users would first
have to migrate to. v1.4.1 declares `pragma solidity >=0.7.0 <0.9.0` and compiles
cleanly under this repo's pinned `solc 0.8.24`.

Safe is LGPL-3.0-only. It is consumed unmodified as a library dependency and no
Safe source file is copied into `src/`; RebaseX contracts remain MIT.
