#!/bin/sh
set -eu
mkdir -p docs/abi
forge inspect src/NOSAND.sol:NOSAND abi --json > docs/abi/NOSAND.json
forge inspect src/AntiSandwichHook.sol:AntiSandwichHook abi --json > docs/abi/AntiSandwichHook.json
