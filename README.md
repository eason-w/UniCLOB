# UniCLOB

UniCLOB is an on-chain spot exchange combining a concentrated-liquidity AMM and a price-time-priority order book in one matching engine. LPs provide persistent liquidity over price ranges; makers place funded limit orders. Trades execute against both in a single transaction.

[Read the technical paper](UniCLOB-Technical-Paper.pdf)

## How it works

The matcher follows the AMM curve to the next resting order price, fills the FIFO queue at that price, then resumes the curve. AMM liquidity has priority along the execution path without bypassing better-priced orders.

LP positions use Uniswap v3 mathematics. Minting and withdrawing touch two endpoints, so work does not grow with range width. Takers pay the same market fee on both liquidity sources: AMM fees are split between LPs and the protocol, while limit-order fees go to the protocol.

A singleton holds market state and settles trades. Traders can swap directly from a wallet; makers can maintain funded balances and batch order amendments.

## Contracts

Start with [`ConcentratedRangeBook.sol`](src/ConcentratedRangeBook.sol), which owns markets, matching and settlement.

| Directory | Contents |
|---|---|
| [`src/libraries`](src/libraries) | Curve math, price indexing, FIFO accounting and settlement |
| [`src/periphery`](src/periphery) | Router, NFT position manager, quoter and lens |
| [`src/interfaces`](src/interfaces) | Standalone Solidity interfaces |
| [`test`](test) | Unit, fuzz, invariant, security and gas tests |
| [`script`](script) | Deployment scripts and local examples |

The paper describes the mechanism and measured tradeoffs. Contract interfaces and NatSpec document the integration API; use `forge inspect <Contract> abi --json` to export an ABI.

## Build and test

Requires Foundry **1.4.4**. Foundry installs the pinned Solidity **0.8.30** compiler; compilation targets Cancun.

```sh
git clone --recurse-submodules https://github.com/eason-w/UniCLOB.git
cd UniCLOB
forge build
forge test
```

Run `FOUNDRY_PROFILE=ci forge test` for the CI fuzz and invariant budgets. Gas benchmarks remain in `test/`; generate local measurements with `forge test --match-contract GasTest --gas-snapshot-emit true`. Snapshots are ignored by Git.

Both deployment scripts use `OPERATOR` and `EXPECTED_CHAIN_ID`. Core also requires `FEE_COLLECTOR`; periphery requires `RANGEBOOK` and `WRAPPED_NATIVE`. Supply signing credentials through Foundry and simulate before broadcasting.

## Status

**Unaudited; no designated public deployment.** Execution is exact-input, resting orders are post-only, and assets must be exact-transfer and non-rebasing.

First-party code is [MIT licensed](LICENSE). Dependencies and test references retain their upstream licenses.
