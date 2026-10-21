# Published Uniswap benchmark artifacts

These JSON artifacts are copied byte-for-byte from official Uniswap npm packages. They are
test-only, deployed locally with their original creation bytecode and constructors. They are
not imported into RangeBook production contracts. This is not a fork of live chain state.

| Package | Artifact | Compiler |
|---|---|---|
| `@uniswap/v3-core@1.0.1` | `UniswapV3Factory.json`, `UniswapV3Pool.json` | 0.7.6, identified by bytecode CBOR metadata |
| `@uniswap/v4-core@1.0.2` | `PoolManager.json` | 0.8.26, Cancun, via IR, 44,444,444 optimizer runs |

V3 pools are created by the published factory. V4 managers are constructed with the test as
owner. Runtime code is not patched with `etch`, and pool storage is not fabricated.
The adapters in `test/benchmarks/UniswapAdapters.sol` compile with the project's Solidity
0.8.30 settings. These are minimal owner-bound benchmark adapters, not Uniswap's NFT position
managers, Universal Router, or production-ready replacement routers.

Archive sources and SHA-256:

- `https://registry.npmjs.org/@uniswap/v3-core/-/v3-core-1.0.1.tgz`:
  `141b001e2a376fff867cb24e0713b2834095cb1250c13aae263d9a646446d329`
- `https://registry.npmjs.org/@uniswap/v4-core/-/v4-core-1.0.2.tgz`:
  `f3db3af55f3d0c52f16abe96e7db12443f243bca1f334962373f95c57611de49`

`sha256.json` records the copied artifact and license hashes. Original license notices are
retained. The v4 artifact's embedded compiler metadata describes its source closure and build.
This artifact reference is separate from the v4.0.0 source closure used for curve differential
tests; those tests and the production math dependency remain unchanged.
