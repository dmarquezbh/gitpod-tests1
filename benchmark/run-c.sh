#!/usr/bin/env bash
# Full suite for the C implementation (pthreads + libpq, gcc -O3 -march=native).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
PGPREFIX="$HOME/.local/opt/pgdev"
if [[ ! -x extra/c/bench || extra/c/bench.c -nt extra/c/bench ]]; then
  gcc -O3 -march=native -pthread -I"$PGPREFIX/usr/include/postgresql" extra/c/bench.c \
    -L"$PGPREFIX/usr/lib/x86_64-linux-gnu" -lpq \
    -Wl,-rpath,"$PGPREFIX/usr/lib/x86_64-linux-gnu" -o extra/c/bench
fi
rm -rf results/c
tools/run-suite.sh --name c --port 18089 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/c -- extra/c/bench 18089
