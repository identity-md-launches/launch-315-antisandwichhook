# Nosandwich (NOSAND)

Implemented contracts, vendored dependencies, Foundry tests, and ABI exports for the Sepolia `lab-anti-sandwich-hook` launch. This is the source contribution; the manifest, independent review, publication, attestation, admission, deployment, and frontend belong to subsequent contributors/services.

`NOSAND` is a zero-argument ERC-20 named **Nosandwich**, symbol **NOSAND**, with 18 decimals. Its constructor mints exactly 1,000,000,000 tokens to `msg.sender` (the launch factory). There is no subsequent mint, burn interface, owner, admin, transfer tax, proxy, pause, upgrade, or sweep.

`AntiSandwichHook(IPoolManager)` inherits the vendored [OpenZeppelin uniswap-hooks v1.2.0 AntiSandwichHook](https://github.com/OpenZeppelin/uniswap-hooks/blob/v1.2.0/src/general/AntiSandwichHook.sol), including its `BaseDynamicAfterFee` settlement and permission machinery. Its only constructor argument is the PoolManager. Constructor validation requires exactly `beforeSwap`, `afterSwap`, and `afterSwapReturnDelta`, corresponding to address bits **0x00c4** under mask **0x3fff**. Every callback, including `unlockCallback`, checks the PoolManager caller. It has no administrative powers.

For a pool with native ETH as currency0, buys (`zeroForOne`) follow the normal v4 curve. The first swap in a block checkpoints the pool and is not clipped. Later token-to-ETH sells are compared with the opening virtual curve. Exact-input sells surrender excess ETH output; exact-output sells pay any missing token input. The hook mints these positive unspecified deltas as ERC-6909 claims and donates them to currently in-range LPs. With zero in-range liquidity, or if `donate` fails, claims remain for permissionless `donateCollected(poolKey)`. No external token transfer is needed for this claim settlement. Non-native currency0 pools get no checkpoint, fee, or other hook effect.

A buy-sandwich's back-run sell cannot monetize the victim's improvement to its execution price: excess output is removed against the pre-buy checkpoint. The tests track the attacker's actual bought tokens and returned ETH and find no trading profit. This guarantee is directional and concerns swap proceeds: sell-front-run/buy-back-run strategies, other pools, cross-block trades, and recapture of fees as an LP remain possible. In particular, JIT LPs can receive the donations; this is demonstrated in a regression test. Dampened arbitrage can leave the pool's price behind the market.

The two required changes to upstream `_beforeSwap` are implemented in the subclass, leaving vendor files unchanged:

1. An empty checkpoint uses `lastTick = currentTick`. At the rehearsal opening tick of about 138,162, starting from zero would otherwise cause roughly 2,303 tick reads/copies before the first buy.
2. The tick-copy loop visits at most **100** tickSpacing steps nearest the current tick. OpenZeppelin warns of `MemoryOOG` for large tick moves; with tickSpacing 60 the uncapped traversal is unsuitable for the launch's transaction gas budget.

Additional correctness adaptations, including partial-fill handling, immutable checkpoint quoting, and the virtual curve's limits, are explained in [docs/DESIGN.md](docs/DESIGN.md). They are material review items, not a claim of byte-for-byte equivalence to upstream.

## Local verification

```sh
forge build
forge test
forge fmt --check
```

The configuration pins **Solidity 0.8.26**, **Cancun**, optimization at 200 runs, and `bytecode_hash = "none"`. FFI and filesystem permissions are disabled. All imported dependencies are ordinary files in `lib/`; no download, environment variable, fork, submodule, wallet, or RPC is required for these commands. [docs/VENDOR.md](docs/VENDOR.md) records revisions and licenses.

The suite uses real v4-core PoolManagers and actually mines/deploys hooks with CREATE2. It covers fixed token supply, ERC-20 failures, permissions, direct-caller rejection, both swap directions and amount modes, dust, partial fills, no-profit buy sandwiches, liquidity changes, per-pool isolation, claim conservation, donation failure/retry, zero-liquidity exits in both currencies, and bounded checkpoint gas. The stateful invariant reconciles `Clipped - Donated`, per-pool balances, aggregate claims, and settled deltas across two pools.

The factory rehearsal performs **token creation → initialize → one-sided NOSAND seed → first buy into an ETH-less manager**, with no special hook initialization or liquidity permissions. It measures the swap separately from deployment and salt mining and cools the relevant contracts first. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the explicit rehearsal parameters and operational responsibilities.

ABI artifacts: [NOSAND.json](docs/abi/NOSAND.json), [AntiSandwichHook.json](docs/abi/AntiSandwichHook.json). Regenerate with `sh scripts/export-abis.sh`. Integration guidance is in [docs/ABI.md](docs/ABI.md).

An independent adversarial review is still a separate required stage. These local results are not an audit, deployment, or admission attestation. No `launch.json` or website is produced by this source assignment.
