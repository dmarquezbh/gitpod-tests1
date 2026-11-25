#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/nim
tools/run-suite.sh --name nim --port 18095 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/nim -- env PORT=18095 nim-platform/server
