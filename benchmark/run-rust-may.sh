#!/usr/bin/env bash
# may-minihttp from TechEmpower: own HTTP server and own pipelined PostgreSQL client on `may` coroutines,
# one connection per core. Unmodified; it hardcodes the host "tfb-database" (mapped in /etc/hosts).
set -euo pipefail
cd "$(dirname "$0")"
grep -q tfb-database /etc/hosts || echo "127.0.0.1 tfb-database" >> /etc/hosts
DURATION="${DURATION:-10}"
( cd rust-may-minihttp && RUSTFLAGS="-C target-cpu=native" cargo build --release )
rm -rf results/rust-may-minihttp
tools/run-suite.sh --name rust-may-minihttp --port 8080 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" --out results/rust-may-minihttp -- rust-may-minihttp/target/release/may-minihttp
