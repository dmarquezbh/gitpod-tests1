#!/usr/bin/env bash
# Stack do Paulo (PR #1), variante epoll em CPython puro, agora com os seis testes.
# db/queries/fortunes/updates usam libpq (C) via ctypes — mesmo cliente do dotnet-platform.
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
OUT="${OUT:-results/paulo-epoll}"
rm -rf "$OUT"
tools/run-suite.sh --name paulo-epoll --port 18091 --tests "plaintext json db queries fortunes updates" \
  --duration "$DURATION" --out "$OUT" -- env PORT=18091 python3 python-platform-epoll/server.py
