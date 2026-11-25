#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/lua
tools/run-suite.sh --name lua --port 18094 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/lua -- env PORT=18094 WORKERS=2 luajit lua-platform/server.lua
