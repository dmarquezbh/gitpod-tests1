#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/dart
tools/run-suite.sh --name dart --port 8099 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/dart -- env PORT=8099 dart-platform/server
