#!/usr/bin/env bash
# Runs plaintext and json against the CPython "platform" implementation (asyncio.Protocol on
# uvloop, hand-written parser, one process per CPU with SO_REUSEPORT).
# PYTHON: interpreter to use. Default: python-platform/.venv, created with uv (Python 3.13) if missing.
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
export PORT="${PORT:-8082}"
if [[ -z "${PYTHON:-}" ]]; then
  PYTHON=python-platform/.venv/bin/python
  if [[ ! -x "$PYTHON" ]]; then
    uv venv -q -p 3.13 python-platform/.venv
    uv pip install -q -p python-platform/.venv -r python-platform/requirements.txt
  fi
fi
rm -rf results/python-platform
tools/run-suite.sh --name python-platform --port "$PORT" --tests "plaintext json" --duration "$DURATION" \
  --out results/python-platform -- "$PYTHON" -O python-platform/server.py
