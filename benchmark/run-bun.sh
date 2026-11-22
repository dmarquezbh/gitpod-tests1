#!/usr/bin/env bash
# Full suite for the unified JavaScript server on Bun.
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
BUN="$HOME/.local/opt/bun/bin/bun"
rm -rf results/bun
tools/run-suite.sh --name bun --port 18090 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/bun -- "$BUN" extra/js/server.js 18090
