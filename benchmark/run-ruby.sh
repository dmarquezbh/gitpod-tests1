#!/usr/bin/env bash
# Full suite for the Ruby implementation (WEBrick + pg pool).
set -euo pipefail
cd "$(dirname "$0")"
DURATION="${DURATION:-10}"
rm -rf results/ruby
tools/run-suite.sh --name ruby --port 18088 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" \
  --out results/ruby -- ruby extra/ruby/app.rb 18088
