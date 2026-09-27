# Local verification record

Verified with Foundry 1.8.3 and the configured Solidity 0.8.26 compiler:

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| `forge test -vv` | 30 passed, 0 failed, 0 skipped |
| `forge test --isolate -q` | Pass |
| `forge fmt --check` | Pass |
| ABI arrays compared with compiled artifacts | Both match |
| Vendored file checksums | All 503 match |
| First factory-rehearsal buy | 283,688 gas; asserted below 1,000,000 |
| First swap after a large tick move | 1,760,444 gas; exactly 100 checkpoint copies |
| NOSAND runtime size | 1,723 bytes |
| AntiSandwichHook runtime size | 14,853 bytes; below EIP-170 |

Each fuzz test runs 256 cases. The stateful accounting invariant runs 64 sequences of 32 calls (2,048 calls), starting with real retained claims. The test helpers do not read or set environment variables. Gas measurements isolate the swap call from deployment and salt mining; transaction intrinsic calldata gas is not included in those call measurements.

Foundry's heuristic lint output includes safe-cast and reentrancy notices. The tick cast is bounded by current/previous valid ticks; quote signs follow a oneForZero swap; donation amounts are bounded to int128.max. The manager-only external mint/donate/burn calls make no receiver callbacks in the pinned real PoolManager, as discussed in `DESIGN.md`. These checks are local verification, not independent adversarial review or launch admission.
