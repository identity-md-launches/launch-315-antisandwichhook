# Vendored source provenance

Dependencies are source files, not submodules. Required source and test utilities are local; building and testing does not install anything. Upstream code is unchanged. The application adaptations live in `src/AntiSandwichHook.sol`.

| Directory | Upstream revision | Included material |
| --- | --- | --- |
| `lib/openzeppelin-uniswap-hooks` | [v1.2.0 / b52f464aa0af8fcd8f16cdad9ae43581deb5cd47](https://github.com/OpenZeppelin/uniswap-hooks/tree/b52f464aa0af8fcd8f16cdad9ae43581deb5cd47) | src, MIT license |
| `lib/v4-core` | [d153b048868a60c2403a3ef5b2301bb247884d46](https://github.com/Uniswap/v4-core/tree/d153b048868a60c2403a3ef5b2301bb247884d46) | src, test CurrencySettler utility, licenses directory |
| `lib/v4-periphery` | [7ebd04b161745b75ed0c24ba2df3bc7c25f65606](https://github.com/Uniswap/v4-periphery/tree/7ebd04b161745b75ed0c24ba2df3bc7c25f65606) | LiquidityAmounts, HookMiner, license |
| `lib/openzeppelin-contracts` | [c64a1edb67b6e3f4a15cca8909c9482ad33a02b0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/c64a1edb67b6e3f4a15cca8909c9482ad33a02b0) | contracts, MIT license |
| `lib/forge-std` | [a6d71da563bbb8d6eef8fbec3a16c61c603d2764](https://github.com/foundry-rs/forge-std/tree/a6d71da563bbb8d6eef8fbec3a16c61c603d2764) | src, Apache/MIT licenses |
| `lib/solmate` | [4b47a19038b798b4a33d9749d25e570443520647](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | Owned.sol for test PoolManager, license |

These are the dependency revisions pinned by the v1.2.0 OpenZeppelin hooks release (and its v4-core dependency). Each Solidity file retains its upstream SPDX license; v4-core uses multiple licenses, including BUSL-1.1 and MIT, so consult its notices rather than assuming every dependency is MIT. SHA-256 file checksums are in `docs/vendor-sha256.txt`; verify with `sha256sum -c docs/vendor-sha256.txt`.
