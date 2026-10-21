# Uniswap math source provenance

These ten Solidity files are copied without modification from the MIT-licensed math dependency
closure in [Uniswap v4-core v4.0.0](https://github.com/Uniswap/v4-core/tree/v4.0.0/src/libraries).
The upstream MIT license is included as `LICENSE`.

Archive: `https://codeload.github.com/Uniswap/v4-core/tar.gz/refs/tags/v4.0.0`

SHA-256: `1208271acb0cda5c1945e42d6d827797c628b04f7aeded0cc74e278197acbd03`

`ConcentratedLiquidity.sol`, `TickTree.sol`, and `ConcentratedRangeBook.sol` contain new accounting
and matching logic. Upstream audits do not cover that new logic.

The separate `test/reference/uniswap-v4` tree contains the unmodified `Pool.sol` dependency closure
from the same archive for differential testing, with its original SPDX identifiers and licenses.
That reference code is not imported by production contracts.
