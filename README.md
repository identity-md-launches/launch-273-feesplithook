# Threeway / THRW

Threeway is a Sepolia test toy. Its token and fees have no value; nothing here promises a return.
This repository delivers the token, fee hook, vendored dependencies, ABI exports and local Foundry
rehearsal. Publication, manifest creation/review, attestation, admission, deployment and the site
belong to the other workflow roles. No transaction has been broadcast by this assignment.

`THRW` is an ordinary OpenZeppelin ERC-20 named **Threeway**, symbol **THRW**, with 18 decimals.
Its zero-argument constructor mints exactly **1,000,000,000 THRW** to `msg.sender` (the factory).
There is no subsequent mint, token burn, transfer tax, owner, pause or upgrade path.

`FeeSplitHook(IPoolManager)` has exactly one constructor argument. All rates are source constants.
It validates all 14 permission bits in its constructor; exactly `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta` and `afterSwapReturnDelta` are enabled (**0x00CC**, mask **0x3FFF**).
Initialization and liquidity changes have no hook callbacks. There is no administrator, setter,
pause, sweep, oracle, external routing or proxy. Only the immutable PoolManager can call either
swap callback or `unlockCallback`.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to **0.8.26**, with Cancun, optimizer 200, no bytecode hash and no CBOR
metadata. FFI and filesystem cheatcode permissions are disabled. Dependencies are ordinary files
under `lib/`; no install, submodule, RPC, environment variable or network access is needed to build
or test once Foundry and the pinned compiler are present. See [dependency pins](DEPENDENCIES.md).

The suite deploys real v4 PoolManagers and CREATE2-mined hooks. It covers all four swap modes,
price-limit failures, dust and rounding, malformed/absent identities, a non-ETH pool, constructor
and callback access failures, donation failure/recovery, pool isolation, payout events, failed and
reentrant claims, deferred donation and JIT capture. The stateful invariant uses two pools, three
recipients and an independent ledger for randomized swaps/claims/donations/burns; each campaign
also drains every bucket. Default fuzz runs: 256; invariant: 128 runs × 64 calls, fail on revert.

## Fee and identity rules

Only pools with native ETH as `currency0` accrue fees. The hook learns `currency1` from the key;
it does not hardcode or authenticate a THRW address. Non-ETH pools return zero hook deltas and
have no accounting or event effects. Native-pool accounting is separated by the entire `PoolId`.

The hook charges `floor(ETH leg / 100)` wei. Let `A` be the magnitude of the user's specified
amount, `E` the ETH actually moved by the AMM before hook adjustments, and `f` the hook fee:

| Mode | Fee | Callback / delta | User's specified amount |
| --- | --- | --- | --- |
| Buy, exact ETH input | `floor(A / 100)` | Before: positive specified `f`; AMM input `A - f` | Pays exactly `A` ETH |
| Sell, exact ETH output | `floor(A / 100)` | Before: positive specified `f`; AMM output `A + f` | Receives exactly `A` ETH |
| Buy, exact THRW output | `floor(E / 100)` | After: positive unspecified `f` | Receives exactly `A` THRW; pays `E + f` ETH |
| Sell, exact THRW input | `floor(E / 100)` | After: positive unspecified `f` | Pays exactly `A` THRW; receives `E - f` ETH |

`afterSwap` verifies the pool filled the adjusted specified amount; otherwise it reverts with
`PartialFill`, rolling back the entire swap. PoolManager wraps that error in `WrappedError`.
Exact-input rounding can consume dust without delivering output; zero fees are allowed and emit
`FeeSplit` with zero shares. Routers/frontends remain responsible for minimum output, maximum
input, deadline and other user slippage controls. The pool's own 3000 ppm LP fee is additional to
the hook's fee and is already reflected in AMM movement. Specified ETH magnitudes exceeding the
positive `int128` range are rejected before fee arithmetic.

For every swap, actual credited shares are:

```text
interfaceShare = valid identity ? floor(fee * 2000 / 10000) : 0
lpShare        = floor(fee * 3000 / 10000)
burnShare      = fee - interfaceShare - lpShare
```

All rounding remainder, and the entire missing-interface share, goes to burn. Identity is the
nonzero address decoded from exactly 32 bytes of canonical `abi.encode(address)` hookData.
Empty, short, long, zero-address and dirty-upper-bit data credit nobody. **hookData is
unauthenticated**: anyone can nominate any address, including themselves. The router/swap callback's
`sender` is never used as a fallback identity and earns nothing merely by routing a trade.

## Claims and payouts

Every nonzero fee mints ERC-6909 ETH claims (currency ID 0) to the hook in the swap. Neither swap
callback takes ETH, donates or invokes an interface recipient. Consequently the first buy into a
pool with no ETH can accrue fees before the router settles its input.

- `claim()` pays the caller's complete interface balance across all pools to the caller.
- `donateAccrued(key)` is permissionless and pays only that pool's LP bucket. Its unlock callback
  burns the claims and calls `PoolManager.donate(key, amount, 0, "")`. No native transfer is needed:
  the positive burn credit offsets the donation debt. No active liquidity causes the manager to
  revert, restoring the complete bucket and claim balance.
- `burnAccrued()` is permissionless and pays all pools' burn buckets to
  `0x000000000000000000000000000000000000dEaD`. This is an ETH transfer to DEAD, not an ERC-20 burn.

All payout balances are zeroed before requesting the hook's own unlock. Claim and burn then burn
claims and `take` ETH directly to the recipient. Empty payouts return zero with no event. Reentry
into any payout is blocked. A recipient rejecting ETH reverts only its claim and preserves its
credit; that recipient must be able to accept native ETH. Payouts must start with the manager
locked; invoking a nonempty payout inside another unlock reverts atomically.

Aggregate claim/burn payouts are constant work regardless of pool count. Epoch numbers invalidate
per-pool pending credits after a payout; subsequent credits lazily start a fresh epoch. Lifetime
totals never reset. See [ABI and event documentation](docs/ABI.md).

For all hook-originated accruals and payouts:

```text
PoolManager.balanceOf(hook, 0)
  == sum(pendingInterface[recipient]) + sum(pendingLP[pool]) + sum(pendingBurn[pool])
  == totalPending()
```

This is asserted against an independent ledger after every invariant action. ERC-6909 permits
any holder to transfer unsolicited claims to any address without a receiver callback. Such an
external gift can create surplus claims and break the *literal* equality; the hook cannot prevent
that, and has no sweep or attribution mechanism for gifts. Monitoring should distinguish surplus
from a deficit. Direct/forced native ETH is similarly outside fee accounting and unrecoverable.

## Launch parameters and responsibilities

[LaunchParameters.sol](script/LaunchParameters.sol) supplies the local rehearsal's concrete inputs:

| Parameter | Value |
| --- | --- |
| Chain | Sepolia, `11155111` |
| Live constructor PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Pool currency0 / currency1 | Native ETH (`address(0)`) / factory-created THRW |
| Pool fee / tick spacing | `3000` / `60` |
| Hook flags | `0x00CC` (204) |
| Proposed initial sqrtPriceX96 | `2505414483750479311864138015696063` |
| Proposed initial price | 1,000,000,000 THRW per ETH; both use 18 decimals |
| Proposed one-sided range | `[-887220, 207240]` |
| Proposed seed allocation | 1,000,000,000 THRW, less liquidity rounding residue |

**The supplied workflow contains neither a numeric manifest price nor production factory source.**
These proposed price/range/allocation inputs are explicit assumptions, not an assertion about an
existing manifest. The manifest contributor must reconcile them with the actual factory inputs;
if they differ, update these constants and rerun the rehearsal before release. The rehearsal's
factory harness receives the whole token supply, CREATE2-deploys the hook, initializes at this
price and supplies only currency1 below that price. It asserts zero manager ETH and zero active
liquidity before the first buy, tests both first-buy modes and then all four modes and payouts.
Rounding residue stays in the harness factory. The production service owns final allocation and
residue policy. Local tests use a freshly deployed real manager at its own address, not relocated
runtime code; they are not a Sepolia fork or evidence of deployment.

The deploying service must mine against the **actual CREATE2 deployer address**, creation bytecode,
and `abi.encode(PoolManager)`. For salt `s`, check the lower 14 bits of
`address(uint160(uint256(keccak256(0xff ++ deployer ++ s ++ keccak256(initCode)))))` equal `0x00CC`.
Any bytecode/compiler/constructor/deployer change requires recomputing that salt. The test miner
demonstrates the algorithm; it never disables constructor validation or etches the hook.

Services own source publication, artifact linkage/attestation, admission and deployment, then the
static frontend labeled `lab-fee-split-hook`. The separate contributor owns `launch.json`; this
assignment does not generate it. Independent reviewers must inspect accepted source and manifest
before release. No independent review or production fork result is claimed here.

Operational callers choose when to donate and burn; recipients claim their own fees. Donation
rewards **liquidity in range when donation executes**, not liquidity present when fees accrued.
There is no snapshot, time lock or JIT defense. The suite demonstrates a late LP with 90% of active
liquidity capturing approximately 90% of a previously accumulated donation. Permissionless timing
also lets others front-run a planned donation. This is a consequence of the requested mechanism.

ABI arrays are delivered at `docs/abi/THRW.json` and `docs/abi/FeeSplitHook.json`. Regenerate them
from the pinned compilation with `bash tools/export-abi.sh` after changing either contract.
