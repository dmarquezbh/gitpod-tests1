#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/zig
# plaintext fica no fast6 (loop HTTP + burst, mesma resposta pré-montada); o resto vai no fast7,
# que faz batching de banco por rodada do epoll com o PostgreSQL no mesmo loop do HTTP.
tools/run-suite.sh --name zig --port 8098 --tests "plaintext" --duration "$DURATION" \
  --out results/zig -- zig-platform/fast6
rm -rf /tmp/zig-fast7
tools/run-suite.sh --name zig --port 8098 --tests "json db queries fortunes updates" --duration "$DURATION" \
  --out /tmp/zig-fast7 -- zig-platform/fast7
tail -n +2 /tmp/zig-fast7/summary.csv >> results/zig/summary.csv
cp /tmp/zig-fast7/*.txt results/zig/
cat results/zig/summary.csv
