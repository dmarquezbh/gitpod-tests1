#!/usr/bin/env bash
# Runs the full suite against the two Go implementations from TechEmpower:
#   go-std   : net/http + jackc/pgx v3 (realistic; "./app -db pgx")   -> results/go-std
#   fasthttp : valyala/fasthttp + pgx v4 pool (platform-level)         -> results/go-fasthttp
# fasthttp hardcodes the database host "tfb-database": map it in /etc/hosts (127.0.0.1 tfb-database).
set -euo pipefail
cd "$(dirname "$0")"
export PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod
DURATION="${DURATION:-10}"
( cd go-std/src && GOAMD64=v3 go build -ldflags="-s -w" -o ../app . )
( cd go-fasthttp/src && GOAMD64=v3 go build -ldflags="-s -w" -o ../app . )
rm -rf results/go-std results/go-fasthttp
tools/run-suite.sh --name go-std --port 8080 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --queries-url "/queries?queries=" --updates-url "/update?queries=" --out results/go-std -- \
  go-std/app -db pgx -db_connection_string "host=127.0.0.1 user=benchmarkdbuser password=benchmarkdbpass dbname=hello_world sslmode=disable"
tools/run-suite.sh --name go-fasthttp --port 8080 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --queries-url "/queries?queries=" --updates-url "/updates?queries=" --out results/go-fasthttp -- \
  go-fasthttp/app
