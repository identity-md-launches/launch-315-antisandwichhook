# Deployment parameters and handoff

| Parameter | Value |
| --- | --- |
| Target network | Sepolia, chain ID 11155111 |
| Token creation artifact | `src/NOSAND.sol:NOSAND` |
| Token constructor arguments | None |
| Token allocation at creation | 1,000,000,000 × 10^18 units to the creating factory |
| Hook creation artifact | `src/AntiSandwichHook.sol:AntiSandwichHook` |
| Hook constructor arguments | Only `IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543)` |
| Hook address flags | `(uint160(address) & 0x3fff) == 0x00c4` |
| Pool currencies | currency0 = native ETH, currency1 = the newly deployed NOSAND |
| Pool LP fee / tickSpacing | 3000 / 60 |
| Checkpoint window / copy bound | One block / 100 tickSpacing steps |
| Compiler / EVM | 0.8.26 / Cancun |
| Optimizer / metadata | Enabled, 200 runs / bytecode hash none |
| Constructor/admin dependencies | No token, owner, treasury, authority, or setter argument |

The local tests accept a freshly deployed manager address as the constructor argument. The production constructor intentionally does not hardcode the Sepolia address; the manifest/service must encode the address above. Deploying to a mined address with the wrong permission bits fails in `BaseHook`'s constructor through `Hooks.validateHookPermissions`.

The CREATE2 salt depends on the **actual deployer address**, creation code, and ABI-encoded PoolManager argument. Mine it with that complete init-code hash; a test's salt or another chain's manager is not reusable. The local `HookDeployment` helper demonstrates the calculation without bypassing constructor validation. The factory can initialize and add liquidity without invoking disabled initialization or liquidity callbacks.

## Rehearsal assumptions needing manifest alignment

The supplied approved workflow does not contain a numeric manifest price, token seed allocation, factory source, or exact tick bounds. No manifest was supplied. The executable `test/helpers/FactoryRehearsal.sol` therefore states these assumptions as constants:

| Rehearsal parameter | Assumed value |
| --- | --- |
| Opening price | 1 NOSAND = 0.000001 ETH; 1 ETH = 1,000,000 NOSAND |
| sqrtPriceX96 | 79228162514264337593543950336000 = 1000 × 2^96 |
| Approximate opening tick | 138162 |
| NOSAND seed | 900,000,000 NOSAND |
| Seed range | [-887220, 138120], multiples of 60 |
| Seed liquidity | `LiquidityAmounts.getLiquidityForAmount1(sqrt(lower), sqrt(upper), seed)` |
| First buy | Exact input, 1 ETH |

The upper tick is below the opening price, so the entire initial position consists of NOSAND and has zero active liquidity at initialization. The first buy crosses into this position. The rehearsal explicitly asserts that the manager holds zero ETH before that buy, and that seed ETH delta is zero. Remaining tokens stay with the rehearsal factory; it does not model an unspecified production supply split or position NFT.

The manifest contributor must align these parameters with the actual factory before signing the launch artifact. If the real launch price/allocation/range differs, update the rehearsal and repeat its gas and swap checks. The tested lifecycle matches the supplied factory description; it is not a fork reproduction of unavailable factory bytecode. Solidity's source constants for checkpoint logic do not depend on the assumed token price.

## Operational ownership

- The manifest contributor writes `launch.json` from accepted artifacts and constructor parameters. Policy and signed artifact linkage are service responsibilities.
- The independent reviewer assesses the accepted source, exported ABI, manifest, and the sequences in `DESIGN.md`; concrete constructor, authorization, source, or policy conflicts remain review findings.
- Publication/attestation/admission/deployment services verify source and chain, mine the actual factory salt, check that the intended Sepolia manager/router/StateView have code, rehearse against that manager, and execute deployment only after admission.
- The frontend contributor builds the static page using deployed addresses and pool ID. Quote both price movement and after-swap deltas; v4 sqrt price limits alone do not cap the hook charge. Enforce end-user min-output/max-input limits in the integration. Read the hook views/events described in `ABI.md`.
- Anyone can trigger deferred donations once in-range liquidity exists. No privileged keeper, owner, or emergency recovery account exists. Operators should monitor retained balances, donation events, first-swap gas, and divergence from external markets. A new block does not update a checkpoint until the next swap.

No wallet, broadcast, live fork, publication, deployment, or service admission was performed in this source contribution. Those later outcomes are not prerequisites for local contract verification.
