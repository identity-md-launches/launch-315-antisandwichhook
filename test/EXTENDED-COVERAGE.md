The extension uses the vendored real PoolManager, the accepted CREATE2 hook miner,
and the accepted factory rehearsal fixture. All dependencies were already vendored;
the tests need no network, environment variables, or compiler configuration changes.
The fixture's launch price is `79228162514264337593543950336000`; no `launch.json`
was present in the input tree, so these tests do not claim to verify a generated manifest.

| File | Additional checks |
| --- | --- |
| `LaunchRehearsal.t.sol` | ETH-less one-sided launch; fuzzed first buys in both modes including dust; distinct attacker and victim balances at launch and later blocks; complete inventory liquidation with no profitable exact-input round trip; insufficient-inventory exact-output back-run rollback; precise empty-checkpoint rejection and next-block retry; unclipped fresh-block sells; first exact-output buy gas. |
| `SwapAccountingExtensions.t.sol` | Exact-output clipping distinguished from ordinary LP fees using an unhooked control pool, including actual LP collection; both claim currencies retained at a zero-liquidity exit; donation inside an existing unlock; outer-transaction rollback; permissionless retry and no double payment; bounded checkpoint gas after large moves in either direction. |
| `Sandwich.invariant.t.sol` | Stateful repeated attacker/victim/back-run sequences with actual wallet accounting, immutable per-block checkpoints, event accounting, and no outstanding claims or deltas. Unexpected reverts fail the run; the setup executes a successful clipped round trip so the invariant cannot pass without exercising protection. |

The pre-existing suite also covers the first exact-input buy gas, direct callback
authorization, non-native pools, deferred cross-pool claim accounting, and donation
failure. It is retained unchanged.

Gas assertions measure the swap call including routing and settlement, excluding
deployment, salt mining, and transaction intrinsic gas. The measured contracts are
cooled with `vm.cool`. First-swap ceiling: 1,000,000 gas. Large-move checkpoint ceiling:
3,000,000 gas, with exactly 100 copied steps. These are regression budgets, not a
network gas estimate. Run with `-vv` for emitted measurements.

One unresolved requirement mismatch is reported in `.imd-findings.json`: the virtual
checkpoint quote ignores initialized liquidity boundaries and can give better fills
than the actual opening pool. The reproduction asserts the desired behavior and
fails for both exact input and exact output. It is preserved as text so the required
passing suite does not bless the defect, hide it behind `expectRevert`, or mark it skipped.

To reproduce the reported failure (the two tests are expected to fail):

```sh
mkdir -p test/scratch
cp test/reproductions/OpeningCurve.t.sol.txt test/scratch/BoundaryProbe.t.sol
forge test --out test/scratch/out --cache-path test/scratch/cache --match-contract BoundaryProbe -vv
```

Remove the scratch Solidity copy before ordinary verification:

```sh
rm test/scratch/BoundaryProbe.t.sol
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The output/cache flags keep local generated files within the assignment's scratch
directory. The delivered tests also work with plain `forge test` after scratch is removed.
