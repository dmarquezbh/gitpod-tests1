#!/usr/bin/env bash
# Full suite for the Python implementation (Starlette + uvicorn + pg8000, 2 workers).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
PY="$HOME/.local/opt/pybench/bin/uvicorn"
rm -rf results/python
tools/run-suite.sh --name python --port 18086 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/python -- "$PY" app:app --host 127.0.0.1 --port 18086 --workers 2 --log-level warning --app-dir extra/python
