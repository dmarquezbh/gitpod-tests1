#!/usr/bin/env bash
# Runs the full suite against the .NET 11 implementation (single process serves all six endpoints).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.dotnet:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# Runtime knobs (same spirit as the TechEmpower aspnetcore entries):
export DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS="${DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS:-0}"  # 1 = socket continuations inline on the IO thread; see RESULTS.md (tuning) for why 0 here
export DOTNET_ReadyToRun=0      # JIT the framework instead of using precompiled R2R code -> full dynamic PGO
export DOTNET_TieredPGO=1
export POSTGRES_MAX_POOL_SIZE="${POSTGRES_MAX_POOL_SIZE:-4}"
DURATION="${DURATION:-10}"
( cd dotnet && dotnet publish -c Release -o out )
rm -rf results/dotnet
tools/run-suite.sh --name dotnet --port 8080 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" --out results/dotnet -- dotnet dotnet/out/DotnetBench.dll
