#!/usr/bin/env bash
# Full suite for the same Python app on GraalPy 3.11 (GraalVM fork of CPython).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
PY="$HOME/.local/opt/pybench-graal/bin/uvicorn"
rm -rf results/graalpy
# GraalPy's select() fallback caps file descriptors at 1024: 512 keep-alive connections crash it.
tools/run-suite.sh --name graalpy --port 18094 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --levels "16 64 256" --pipeline-levels "256" --max-concurrency 256 --out results/graalpy -- "$PY" app:app --host 127.0.0.1 --port 18094 --workers 2 --log-level warning --app-dir extra/python
