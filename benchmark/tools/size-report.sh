#!/usr/bin/env bash
# Reports deployable size and peak RSS per implementation.
# app_bytes   = what you ship for the app (binary, published folder, node_modules+source)
# runtime_bytes = runtime/dependencies that must be installed on the machine
# peak_rss_kb = summed VmHWM of the server process tree during the benchmark suite
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=results/metrics.csv
echo "impl,app_bytes,runtime_bytes,total_bytes,peak_rss_kb" > "$OUT"

bytes() { # bytes <path...> : sum of sizes (files or directories), 0 if missing
  local total=0 p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    total=$((total + $(du -sb "$p" | cut -f1)))
  done
  echo "$total"
}

rss() { cat "results/$1/peak_rss_kb.txt" 2>/dev/null || echo ""; }

emit() { # emit <impl> <app_bytes> <runtime_bytes>
  local impl=$1 app=$2 rt=$3
  echo "$impl,$app,$rt,$((app + rt)),$(rss "$impl")" >> "$OUT"
}

DOTNET_RT=$(bytes "$HOME/.dotnet/shared/Microsoft.NETCore.App/11.0.0" "$HOME/.dotnet/shared/Microsoft.AspNetCore.App/11.0.0")
JAVA_HOME_DIR=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
RUBY_BIN=$(readlink -f "$(command -v ruby)")
RUBY_LIB=$(readlink -f /usr/lib/x86_64-linux-gnu/libruby-3.2.so.3.2.3 2>/dev/null || true)
PY_BIN=$(readlink -f "$(command -v python3)")
PY_STDLIB=$(python3 -c 'import sysconfig;print(sysconfig.get_path("stdlib"))' 2>/dev/null || true)
NODE_BIN=$(readlink -f "$(command -v node)")
GEMDIR="$HOME/.local/share/gem/ruby/3.2.0"
LIBPQ=$(bytes "$HOME/.local/opt/pgdev/usr/lib/x86_64-linux-gnu/libpq.so.5.16")

emit rust "$(bytes rust-axum/target/release/axum rust-axum/target/release/axum-pg)" 0
emit rust-tuned "$(bytes rust-axum-tuned/target/release/axum rust-axum-tuned/target/release/axum-pg)" 0
emit rust-may-minihttp "$(bytes rust-may-minihttp/target/release/may-minihttp)" 0
emit dotnet "$(bytes dotnet/out)" "$DOTNET_RT"
emit dotnet-platform "$(bytes dotnet-platform/out)" "$DOTNET_RT"
emit go-std "$(bytes go-std/app)" 0
emit go-fasthttp "$(bytes go-fasthttp/app)" 0
emit java "$(bytes extra/java/out extra/java/postgresql.jar)" "$(bytes "$JAVA_HOME_DIR")"
emit python "$(bytes extra/python "$HOME/.local/opt/pybench")" "$(bytes "$PY_BIN" "$PY_STDLIB")"
emit pypy "$(bytes extra/python "$HOME/.local/opt/pybench-pypy")" "$(bytes "$HOME/.local/share/uv/python/pypy-3.11.15-linux-x86_64-gnu")"
emit graalpy "$(bytes extra/python "$HOME/.local/opt/pybench-graal")" "$(bytes "$HOME/.local/share/uv/python/graalpy-3.11.0-linux-x86_64-gnu")"
emit node "$(bytes extra/js)" "$(bytes "$NODE_BIN")"
emit bun "$(bytes extra/js)" "$(bytes "$HOME/.local/opt/bun")"
emit deno "$(bytes extra/js)" "$(bytes "$HOME/.local/opt/deno")"
emit ruby "$(bytes extra/ruby "$GEMDIR/gems/pg"* "$GEMDIR/gems/rack"* "$GEMDIR/gems/webrick"*)" "$(bytes "$RUBY_BIN" "$RUBY_LIB" /usr/lib/ruby)"
emit c "$(bytes extra/c/bench)" "$LIBPQ"
emit cpp "$(bytes extra/cpp/bench)" "$LIBPQ"
emit zero "$(bytes extra/zero/bench)" "$LIBPQ"

column -s, -t "$OUT"
