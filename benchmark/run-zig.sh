#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/zig
tools/run-suite.sh --name zig --port 8098 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/zig -- zig-platform/fast6
