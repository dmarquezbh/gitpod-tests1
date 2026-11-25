#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/kotlin
tools/run-suite.sh --name kotlin --port 8096 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out results/kotlin -- env PORT=8096 java -cp "kotlin-platform/server.jar:$HOME/src/postgresql.jar" ServerKt
