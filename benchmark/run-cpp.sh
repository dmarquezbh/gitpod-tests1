#!/usr/bin/env bash
# Full suite for the C++ implementation (epoll + libpq batching). Updates are skipped:
# concurrent UNNEST UPDATEs deadlock in PostgreSQL (the same SQL used by .NET/Rust).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
PGPREFIX="$HOME/.local/opt/pgdev"
if [[ ! -x extra/cpp/bench || extra/cpp/server.cpp -nt extra/cpp/bench ]]; then
  g++ -O3 -march=native -pthread -std=c++20 -I"$PGPREFIX/usr/include/postgresql" extra/cpp/server.cpp \
    -L"$PGPREFIX/usr/lib/x86_64-linux-gnu" -lpq -Wl,-rpath,"$PGPREFIX/usr/lib/x86_64-linux-gnu" -o extra/cpp/bench
fi
rm -rf results/cpp
tools/run-suite.sh --name cpp --port 18095 --tests "plaintext json db queries fortunes" --duration "$DURATION" \
  --out results/cpp -- extra/cpp/bench
