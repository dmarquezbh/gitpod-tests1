#!/usr/bin/env bash
# Full suite for the unified JavaScript server on Deno (CommonJS + node_modules).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
DENO="$HOME/.local/opt/deno/bin/deno"
rm -rf results/deno
tools/run-suite.sh --name deno --port 18091 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/deno -- "$DENO" run -A --node-modules-dir=auto extra/js/server.js 18091
