#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/pascal
tools/run-suite.sh --name pascal --port 18096 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/pascal -- env PORT=18096 pascal-platform/server
