#!/usr/bin/env bash
# Full suite for the unified JavaScript server on Node.
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/node
tools/run-suite.sh --name node --port 18087 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/node -- node extra/js/server.js 18087
