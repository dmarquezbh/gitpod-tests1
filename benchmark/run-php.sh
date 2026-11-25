#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/php
tools/run-suite.sh --name php --port 18093 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/php -- \
  env PORT=18093 php-platform/start.sh
