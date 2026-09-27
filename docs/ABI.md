# Contract interfaces

Machine-readable standard ABI arrays: [THRW](abi/THRW.json), [FeeSplitHook](abi/FeeSplitHook.json).
Amounts are raw 18-decimal token units or wei. `PoolId` is `bytes32`, computed by
`keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))` in v4's field order.
`PoolKey` is `(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)`.

## THRW

The constructor has no arguments. Standard ERC-20 methods: `name()`, `symbol()`, `decimals()`,
`totalSupply()`, `balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`,
`transfer(address,uint256)`, `transferFrom(address,address,uint256)`. Standard `Transfer` and
`Approval` events and OpenZeppelin IERC-6093 errors are included in the ABI.

## FeeSplitHook views

| Method | Result |
| --- | --- |
| `poolManager()` | Immutable manager address |
| `getHookPermissions()` | 14 booleans in Uniswap's `Hooks.Permissions` order; only four swap flags true |
| `BPS()` / `FEE_BPS()` | `10000` / `100` |
| `INTERFACE_BPS()` / `LP_BPS()` / `BURN_BPS()` | `2000` / `3000` / `5000` nominal split rates |
| `BURN_ADDRESS()` | Fixed DEAD address |
| `lifetimeTotals(bytes32 poolId)` | `(interfaceTotal, lpTotal, burnTotal)`, amounts ever accrued; actual diversion included |
| `pendingInterface(address recipient)` | Aggregate claimable by this recipient across all pools |
| `pendingInterfaceForPool(bytes32 poolId,address recipient)` | This recipient's unclaimed contribution from this pool |
| `pendingLP(bytes32 poolId)` | Pool's undonated LP bucket |
| `pendingBurn(bytes32 poolId)` | Pool's unburned bucket |
| `totalPendingInterface()` / `totalPendingLP()` / `totalPendingBurn()` | Corresponding aggregate obligations |
| `totalPending()` | Sum of all three aggregate obligations |

After `claim()`, that caller's pending views are zero in every pool. After `burnAccrued()`, every
pool's burn pending view is zero. LP donation affects only the supplied key. Lifetime values are
never reduced. Per-pool interface totals across recipients can be indexed from `FeeSplit` and
`Claimed`; the contract does not enumerate recipients or pools.

## Actions

| Method | Authorization and return |
| --- | --- |
| `claim()` | Caller claims only their balance, to themselves; returns `uint256 amount` |
| `burnAccrued()` | Anyone; all pending burn claims go to DEAD; returns `uint256 amount` |
| `donateAccrued(PoolKey key)` | Anyone; requires native currency0 and this hook in key; returns `uint256 amount` |

All three are nonpayable and protected from payout reentrancy. They invoke the hook's own manager
unlock only when an amount is pending. They cannot be used as callbacks in somebody else's unlock.
There is no batch enumeration, alternate claim recipient or admin withdrawal.

`beforeSwap(address,PoolKey,SwapParams,bytes)` and
`afterSwap(address,PoolKey,SwapParams,int256,bytes)` implement the v4 callbacks. `BalanceDelta`
is an `int256` packing two signed `int128` deltas; `BeforeSwapDelta` similarly packs specified and
unspecified deltas. `SwapParams` is `(bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96)`.
`unlockCallback(bytes)` is for PoolManager only and additionally requires an active hook payout.
These are infrastructure callbacks, not frontend transaction entrypoints. Disabled v4 callback
selectors are absent from the ABI and revert if manually called.

## Events

| Event | Interpretation |
| --- | --- |
| `FeeSplit(bytes32 indexed poolId,address indexed interfaceAddress,uint256 fee,uint256 interfaceShare,uint256 lpShare,uint256 burnShare)` | One per successful native-pool swap, including zero fee. Shares are actual credits and sum exactly to fee. `interfaceAddress == 0` means no valid identity. |
| `Donated(bytes32 indexed poolId,uint256 amount)` | Nonzero LP bucket settled for this pool |
| `Burned(uint256 amount)` | Aggregate burn across every pool; reset all tracked pool burn pending amounts |
| `Claimed(address indexed interfaceAddress,uint256 amount)` | Aggregate interface payout; reset this recipient's pending amounts in all pools |

`Burned` and `Claimed` aggregation is intentional: their amounts cover the entire pending balance
at that transaction. Failed operations revert all logs. Indexers should process transaction/log
order, handle chain reorganizations, and use view calls to reconcile current balances.

## Errors

Hook errors: `NotPoolManager`, `InvalidPoolManager`, `InvalidPool`, `PartialFill`,
`SwapAmountTooLarge`, `ReentrantPayout`, `UnexpectedUnlock`. Constructor permission errors use
`Hooks.HookAddressNotValid(address)`. Manager donation may revert `NoLiquidityToReceiveFees()`;
nested payout may revert `AlreadyUnlocked()`. Manager failures, including failed native payouts,
propagate. Swap callback errors are wrapped by v4's
`WrappedError(address target,bytes4 selector,bytes reason,bytes details)`.
