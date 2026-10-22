#!/usr/bin/env bash
# Runs the full suite against the .NET 11 "platform" implementation (own HTTP/1.1 loop over
# Kestrel's socket transport; single process serves all six endpoints).
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.dotnet:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS="${DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS:-1}"
export DOTNET_ReadyToRun=0
export DOTNET_TieredPGO=1
# Final configuration (see RESULTS.md, "tuning"): raw socket HTTP loop, raw pipelined PostgreSQL client
# with one connection per IO thread, Nagle left on for the PostgreSQL sockets (kernel-side coalescing),
# workstation non-concurrent GC with a 64 MB gen0 budget.
export HTTP_TRANSPORT="${HTTP_TRANSPORT:-raw}"                      # raw | kestrel-sockets
export DB_DRIVER="${DB_DRIVER:-raw}"                                # raw | npgsql
export POSTGRES_RAW_CONNECTIONS="${POSTGRES_RAW_CONNECTIONS:-2}"    # raw driver: primary connections (one per IO thread)
export POSTGRES_RAW_HEAVY_CONNECTIONS="${POSTGRES_RAW_HEAVY_CONNECTIONS:-4}"  # raw driver: connections reserved for multi-row queries and updates
export PG_NODELAY="${PG_NODELAY:-0}"                                # raw driver: 0 = leave Nagle on
export POSTGRES_MAX_POOL_SIZE="${POSTGRES_MAX_POOL_SIZE:-2}"        # npgsql driver: pool per data source
export POSTGRES_DATA_SOURCES="${POSTGRES_DATA_SOURCES:-4}"          # npgsql driver: independent data sources
export DOTNET_gcServer="${DOTNET_gcServer:-0}"
export DOTNET_gcConcurrent="${DOTNET_gcConcurrent:-0}"
export DOTNET_GCgen0size="${DOTNET_GCgen0size:-0x4000000}"
DURATION="${DURATION:-10}"
( cd dotnet-platform && dotnet publish -c Release -o out )
rm -rf results/dotnet-platform
tools/run-suite.sh --name dotnet-platform --port 8081 --tests "plaintext json db queries fortunes updates" --duration "$DURATION" --out results/dotnet-platform -- dotnet dotnet-platform/out/DotnetBench.Platform.dll
