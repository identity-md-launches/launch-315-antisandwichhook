# Contract interfaces

The JSON files in `docs/abi/` are compiler-produced ABI arrays. They include inherited ERC-20 and hook interfaces, errors, and events. Reproduce them using `sh scripts/export-abis.sh` after a successful build.

| Contract / entry point | Use |
| --- | --- |
| `NOSAND()` | Mint the fixed supply to the deployer. |
| ERC-20 metadata, balance, transfer, approval functions | Standard OpenZeppelin ERC-20, 18 decimals; transfer failures use standard custom errors. |
| `AntiSandwichHook(IPoolManager)` | Bind the immutable manager and validate address flags. |
| `poolManager()` | Manager configured at construction. |
| `getHookPermissions()` | Fourteen named flags; only beforeSwap, afterSwap, afterSwapReturnDelta are true. |
| `MAX_CHECKPOINT_TICKS()` | Source constant 100. |
| `checkpoint(bytes32 poolId)` | Returns `(uint256 blockNumber, uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint16 ticksCopied)`. Unobserved pools return zeros. The state does not move during same-block quoting. |
| `collected(bytes32 poolId, address currency)` | Collected-but-undonated units, ETH represented by address zero. |
| `donateCollected(PoolKey)` | Permissionless donation/retry. No ETH value or token approval needed. Returns no value. Zero balance or zero active liquidity is a no-op. Wrong hook in the key reverts. |
| Hook callbacks and `unlockCallback(bytes)` | Manager-only entry points; never call them from a frontend. Disabled hook callbacks are not invoked by v4. |

`PoolKey` is the tuple `(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)`. The pool ID is `keccak256(abi.encode(poolKey))`, using ABI encoding of its five fields. The hook accepts any native-currency0 pool using this hook, not just the launch token; accounting remains isolated by ID.

| Event | Indexed fields | Data |
| --- | --- | --- |
| `Clipped(bytes32 poolId, uint256 blockNumber, address currency, uint256 amount)` | poolId, blockNumber, currency | amount |
| `Donated(bytes32 poolId, address currency, uint256 amount)` | poolId, currency | amount |
| Inherited `HookFee(bytes32,address,uint128,uint128)` | See exported ABI | Upstream attribution to the router sender, not authenticated end-user identity. Do not double-count it with Clipped. |

For a recent sells list, index `Clipped` by hook address and pool ID, retaining transaction hash and log index for ordering and reorg handling. Not every sell clips, so a complete sell history also requires PoolManager Swap events. `Clipped` reports a charged amount, not an authenticated trader identity. Exact-input sell charges are ETH; exact-output sell charges are NOSAND. Both use 18 decimals in the intended pool.

The checkpoint price in NOSAND per ETH is `sqrtPriceX96² / 2^192`; invert it for ETH per NOSAND. Use full-width integer/rational arithmetic rather than JavaScript Number for squaring. Fetch the current price from the deployed chain's StateView/PoolManager. Display the checkpoint block alongside the price so a stale checkpoint during an idle block is apparent.

`CheckpointCannotFillExactOutput` means the opening virtual curve cannot fill the executed output, including a zero-liquidity opening checkpoint. An exact-input sell in the latter case can be entirely clipped. The UI must quote the hook-adjusted result and clearly handle these cases.
