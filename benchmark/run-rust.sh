#!/usr/bin/env bash
# Runs the full suite against the Rust/axum implementation (two binaries, as in TechEmpower:
# `axum` serves plaintext+json, `axum-pg` (tokio-postgres) serves db/queries/fortunes/updates).
set -euo pipefail
cd "$(dirname "$0")"
export POSTGRES_URL="${POSTGRES_URL:-postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world}"
DURATION="${DURATION:-10}"
( cd rust-axum && RUSTFLAGS="-C target-cpu=native" cargo build --release --bin axum --bin axum-pg )
rm -rf results/rust; mkdir -p results/rust
tools/run-suite.sh --name rust --port 8000 --tests "plaintext json" --duration "$DURATION" --out results/rust-platform -- rust-axum/target/release/axum
tools/run-suite.sh --name rust --port 8000 --tests "db queries fortunes updates" --duration "$DURATION" --out results/rust-pg -- rust-axum/target/release/axum-pg
{ head -1 results/rust-platform/summary.csv; tail -n +2 results/rust-platform/summary.csv; tail -n +2 results/rust-pg/summary.csv; } > results/rust/summary.csv
cp results/rust-platform/*.txt results/rust-platform/server.log results/rust/ 2>/dev/null || true
for f in results/rust-pg/*.txt; do cp "$f" results/rust/; done; cp results/rust-pg/server.log results/rust/server-pg.log
rm -rf results/rust-platform results/rust-pg
echo; echo "Rust summary:"; cat results/rust/summary.csv
