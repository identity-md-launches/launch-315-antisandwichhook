# Pricing and accounting design

## Upstream basis and local changes

The unmodified v1.2.0 vendor source is retained. `src/AntiSandwichHook.sol` inherits its permission declaration, PoolManager authorization, transient target slots, positive after-swap delta calculation, ERC-6909 mint, and `HookFee` event. The hook does not use dynamic LP fees and works with the requested static fee 3000 pool.

The native-pool guard surrounds checkpointing and target application. The subclass has its own PoolId-keyed checkpoint because the upstream mapping is private. An explicit initialized bit also makes block zero work correctly. The opening checkpoint consists of slot0 (including fees), liquidity, global fee growth, and up to 100 tick records traversed from the current tick toward the previous checkpoint tick. Empty checkpoints copy only the current tick. Widened loop arithmetic prevents int24 overflow near tick bounds. No liquidity or initialize callback is enabled.

The following corrections accompany the required empty-checkpoint and 100-step changes:

| Case | Adaptation and reason |
| --- | --- |
| First swap of a block | Never clipped. The real pool is already executing against the captured state. This also ensures that a lone sell crossing actual initialized ticks is not taxed by the virtual model. |
| Partial fill | Before-swap sets the transient application flag; after-swap simulates the **actually filled specified amount**, then lets `BaseDynamicAfterFee` apply the result. Using the original requested amount can undercharge a partial exact-input sell or overcharge partial exact-output. |
| Simulation writes storage | `Pool.swap` writes slot0 and fee growth, despite the upstream comment describing calculation only. The subclass saves/restores those fields so every quote and the public view retain the opening state. Virtual liquidity cannot change because its bitmap is empty. |
| Price limit inside the buy's move | The user's sqrt limit governs the real v4 swap. The virtual sell uses the maximum valid sqrt limit, avoiding a false invalid-price-limit failure when the opening price differs. Router output/input bounds must include the hook delta. |
| Empty virtual liquidity | Exact-input sells have zero target output and are fully clipped. Exact-output sells with nonzero filled output revert with `CheckpointCannotFillExactOutput`; otherwise the upstream zero input quote would let them bypass protection. They can be retried in a block with an executable opening checkpoint. |
| Insufficient virtual exact-output capacity | Reject rather than use the input quote for an unfilled output amount. |

## Meaning of the price bound

As in OZ v1.2, the checkpoint's tick bitmap is **not populated**. Its simulation is a constant-liquidity virtual curve starting at the opening slot0, not a full clone of all concentrated-liquidity positions. The copied tick records do not turn it into such a clone. The loop cap therefore does not cause an unbounded fallback or disable sell protection beyond the copied region.

With ETH as currency0, token-per-ETH price is `(sqrtPriceX96 / 2^96)^2`. A virtual sell raises sqrt price monotonically, giving no more ETH per token than the opening marginal price, with fee and rounding reducing it further. The real trade keeps its worse result or is clipped to the virtual result. Same-block changes to real liquidity cannot alter that saved virtual curve or its opening-price ceiling. Two regression tests compare exact-input and exact-output results to an unmoved real pool with the same liquidity and no crossed boundaries.

This is **not** a claim that the virtual quote equals a hypothetical swap across arbitrary historical initialized ticks. Nor does a truncated copy preserve the entire tick topology. An independent reviewer must assess this inherited model against the intended launch range and any later LP activity. Opening state means immediately before the first swap, so liquidity additions before that swap are included; this hook does not observe the beginning of a block without a swap.

## Claim settlement

For clipped amount `F` in the unspecified currency:

1. The inherited handler calls `manager.mint(hook, currencyId, F)`. The hook has a claim balance `+F` and transient delta `-F`.
2. Its ledger increases by `F` and emits `Clipped(poolId, block.number, currency, F)`.
3. If in-range liquidity is nonzero, `manager.donate` debits the hook by the donation amount. Only a successful donate is followed by burning the same number of claims, which credits the hook's transient delta by that amount. Each ledger reduction emits `Donated`.
4. Returning positive unspecified delta `F` credits the hook `+F` and charges the swapper `F`. The original mint debt is now settled.

A failed `donate` rolls back that external call, and the original claims and ledger remain. Zero liquidity avoids the call entirely. A later permissionless call opens its own manager unlock when needed, then donates and burns equal amounts; there is no take/transfer/settle round trip. When the manager is already unlocked it can do the same work directly. Donations are split at `int128.max` per currency so accumulated claims cannot overflow `Pool.donate`'s amount representation. Excess remains for another call.

After each completed unlock, for each currency:

```text
sum(pool collected[currency]) = sum(Clipped[currency]) - sum(Donated[currency])
                            = hook ERC-6909 balance for that currency
hook transient currency delta = 0
```

Claims are fungible by currency at the manager, so the separate PoolId ledger is essential to prevent cross-pool donation. The equality assumes nobody deliberately transfers unsolicited ERC-6909 claims to the hook; such gifts increase the raw balance without crediting a pool, and have no sweep path. The hook never authorizes another party to burn or transfer its claims.

The trusted PoolManager's `mint`, `burn`, and `donate` do not call tokens or external receivers. Donate hooks are disabled and the donated key must belong to this hook. A mock-induced donation failure tests the catch path; real-manager tests exercise zero-liquidity retention and later payment. Funding failures, invalid user limits, or an unfillable protected exact-output quote can still revert swaps; donation failure itself does not.

## Review targets and known economic boundaries

The independent reviewer should reproduce these concrete sequences:

- Buy → victim buy → sell exactly the first buyer's tokens in one block. Verify ETH returned does not exceed the first buyer's spend, for exact input and exact output variants.
- Buy → add/remove liquidity → sell in the same block. Verify checkpoint invariance and the opening-price ceiling, including range boundaries and partial fills.
- Initialize at launch price → token-only seed → first buy. Verify the empty snapshot does not walk from zero; move more than 100 spacings → advance block → swap to verify the cap.
- Buy → add a large in-range JIT position → clipped sell → collect JIT fees. `test_jitLpReceivesItsDonationShare` demonstrates 90% donation capture by a 90% liquidity position. This design has no LP age restriction and does not prevent that recapture.
- Buy → sell to the last upper boundary → inspect retained claims → add liquidity → call `donateCollected`. Repeat with exact output (NOSAND claims), multiple pools sharing ETH, and a caller already in an unlock.
- Launch with zero opening active liquidity → buy → exact-output sell in the same block. Verify rejection of an unfillable checkpoint, rather than a zero-input target.
- Compare the bounded virtual model to upstream and to real pools with initialized ticks, changing protocol fees, very small liquidity, and extreme sizes. Assess the inherited int128 amount limits and fee rounding.

Buys are unprotected. There is no router identity policy, referral reward, keeper reward, off-chain oracle, or user authentication; hookData is ignored and is unauthenticated. LPs at donation time receive retained fees, which may differ from the LPs present when the fees were clipped. Prices may lag other markets because same-block arbitrage is dampened. These economic limitations are part of the chosen design and must be surfaced by the separate release review.
