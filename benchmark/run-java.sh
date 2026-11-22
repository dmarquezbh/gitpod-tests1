#!/usr/bin/env bash
# Full suite for the Java implementation (JDK HttpServer + virtual threads + JDBC).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/java
tools/run-suite.sh --name java --port 18085 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/java -- java -cp extra/java/out:extra/java/postgresql.jar Bench 18085
