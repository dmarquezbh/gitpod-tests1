#!/usr/bin/env bash
# Full suite for the Zero C# implementation (native binary: pthreads + epoll + libpq).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
PGPREFIX="$HOME/.local/opt/pgdev"
if [[ ! -x extra/zero/bench || extra/zero/Program.cs -nt extra/zero/bench ]]; then
  PG_PREFIX="$PGPREFIX" extra/zero/build.sh
fi
rm -rf results/zero
PORT_NUM=18092 tools/run-suite.sh --name zero --port 18092 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/zero -- env PORT_NUM=18092 extra/zero/bench
