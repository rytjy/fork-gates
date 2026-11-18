#!/usr/bin/env bash
# 复跑 ForkSmoke（B 线 level 1）。三个条件缺一不可，见 audits/2026-11-18-fork-level1.md
# 用法: ./run_fork.sh [block] [test-contract]
set -euo pipefail
export ETH_RPC="${ETH_RPC:?set ETH_RPC to an archive-capable RPC URL}"
BLOCK="$1"; if [ -z "$BLOCK" ]; then BLOCK=26441482; fi
SUITE="$2"; if [ -z "$SUITE" ]; then SUITE=ForkSmoke; fi
cd "$(dirname "$0")"
exec forge test --fork-url "$ETH_RPC" --fork-block-number "$BLOCK" --compute-units-per-second 1 --fork-retry-backoff 3 --match-contract "$SUITE" -vv
