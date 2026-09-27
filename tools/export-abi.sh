#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p docs/abi
forge build
forge inspect src/THRW.sol:THRW abi --json > docs/abi/THRW.json
forge inspect src/FeeSplitHook.sol:FeeSplitHook abi --json > docs/abi/FeeSplitHook.json
