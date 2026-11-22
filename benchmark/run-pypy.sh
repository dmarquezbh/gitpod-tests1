#!/usr/bin/env bash
# Full suite for the same Python app on PyPy 3.11 (JIT fork of CPython).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
PY="$HOME/.local/opt/pybench-pypy/bin/uvicorn"
rm -rf results/pypy
tools/run-suite.sh --name pypy --port 18093 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/pypy -- "$PY" app:app --host 127.0.0.1 --port 18093 --workers 2 --log-level warning --app-dir extra/python
