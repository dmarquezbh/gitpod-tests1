#!/usr/bin/env bash
# Sobe o servidor Elixir "fast" (gen_tcp cru + batching de banco) na porta do harness.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="${HOME}/.local/elixir-1.18/bin:${PATH}"
export PORT="${PORT:-8098}"
export MIX_ENV="${MIX_ENV:-prod}"
exec elixir --erl "+sbwt none +sbwtdcpu none +sbwtdio none" -S mix run --no-halt -e 'Fast.main()'
