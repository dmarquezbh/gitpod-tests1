#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/cobol
tools/run-suite.sh --name cobol --port 18099 --tests "plaintext json" \
  --duration "$DURATION" --out results/cobol -- env COB_CONFIG_DIR=/etc/gnucobol cobol-platform/server
