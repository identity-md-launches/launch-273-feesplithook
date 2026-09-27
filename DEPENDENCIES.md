# Vendored dependency provenance

All dependencies are ordinary repository files, not submodules. No dependency install is needed.
Upstream content was fetched by immutable commit; source headers and license files are retained.
Only the listed subtrees needed to compile or test are included. No upstream scripts, environment
files, node_modules, git metadata or CI directories were imported.

| Dependency | Pinned commit | Included |
| --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/`, except test helpers other than PoolTestBase/PoolSwapTest/PoolModifyLiquidityTest; `test/utils/CurrencySettler.sol`; `licenses/` |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/dbb6104ce834628e473d2173bbc9d47f81a9eec3) | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` (v5.0.2) | ERC20, IERC20, IERC20Metadata, Context, IERC6093 and LICENSE |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol` (PoolManager's dependency), LICENSE |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/bf647bd6046f2f7da30d0c2bf435e5c76a780c1b) | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` (v1.16.2) | `src/` and both licenses |

The v4-core pin uses standalone `SwapParams`/`ModifyLiquidityParams` in `types/PoolOperation.sol`,
as required by the provided protected checks. No claim is made that this source commit is the
verified deployed Sepolia manager bytecode; the service's fork rehearsal must check its target.
Production THRW uses only OpenZeppelin's ERC-20 closure. Production FeeSplitHook imports only
v4 interfaces/types/libraries; PoolManager, routers, Owned and forge-std are used in local tests.

`dependencies.sha256` records each vendored file. Verify with `sha256sum -c dependencies.sha256`.
