#!/usr/bin/env bash
# Rust/axum with the same layout tricks as the .NET platform variant: per runtime thread, one primary
# tokio-postgres connection plus POSTGRES_HEAVY_CONNECTIONS reserved for multi-row queries/updates;
# simd-json for serialization; panic=abort. Everything else is the TechEmpower code.
set -euo pipefail
cd "$(dirname "$0")"
export POSTGRES_URL="${POSTGRES_URL:-postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world}"
export POSTGRES_HEAVY_CONNECTIONS="${POSTGRES_HEAVY_CONNECTIONS:-2}"
DURATION="${DURATION:-10}"
( cd rust-axum-tuned && RUSTFLAGS="-C target-cpu=native" cargo build --release --bin axum --bin axum-pg --features simd-json )
rm -rf results/rust-tuned; mkdir -p results/rust-tuned
tools/run-suite.sh --name rust-tuned --port 8000 --tests "plaintext json" --duration "$DURATION" --out results/rust-tuned-platform -- rust-axum-tuned/target/release/axum
tools/run-suite.sh --name rust-tuned --port 8000 --tests "db queries fortunes updates" --duration "$DURATION" --out results/rust-tuned-pg -- rust-axum-tuned/target/release/axum-pg
{ head -1 results/rust-tuned-platform/summary.csv; tail -n +2 results/rust-tuned-platform/summary.csv; tail -n +2 results/rust-tuned-pg/summary.csv; } > results/rust-tuned/summary.csv
cp results/rust-tuned-platform/*.txt results/rust-tuned-platform/server.log results/rust-tuned/ 2>/dev/null || true
for f in results/rust-tuned-pg/*.txt; do cp "$f" results/rust-tuned/; done; cp results/rust-tuned-pg/server.log results/rust-tuned/server-pg.log
rm -rf results/rust-tuned-platform results/rust-tuned-pg
echo; cat results/rust-tuned/summary.csv
