#!/usr/bin/env bash
# Replica of the TechEmpower wrk suite (toolset/wrk/{concurrency,pipeline,query}.sh) runnable
# without Docker, with the server and wrk pinned to disjoint CPU sets so both implementations
# are measured under identical conditions.
#
# Usage:
#   run-suite.sh --name NAME --port PORT --tests "plaintext json ..." [options] -- <server command...>
#
# Options (defaults mirror the TFB scripts, scaled down for a small box):
#   --server-cpus 0-1     CPUs the server is pinned to (taskset)
#   --wrk-cpus 2-3        CPUs wrk is pinned to (taskset); wrk threads = number of CPUs in this set
#   --duration 10         seconds per level (TFB: 15)
#   --levels "16 64 256 512"             concurrency levels for json/db/fortunes (TFB: 16 32 64 128 256 512)
#   --pipeline-levels "256 1024 4096"    for plaintext (TFB: 256 1024 4096 16384), pipeline depth 16
#   --query-levels "1 5 10 20"           for queries/updates (TFB: 1 5 10 15 20), at --max-concurrency
#   --max-concurrency 512
#   --out DIR             results directory (default: results/NAME)
set -euo pipefail

NAME=""; PORT=""; TESTS=""; SERVER_CPUS="0-1"; WRK_CPUS="2-3"; DURATION=10
LEVELS="16 64 256 512"; PIPELINE_LEVELS="256 1024 4096"; QUERY_LEVELS="1 5 10 20"; MAX_CONCURRENCY=512; PIPELINE=16; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2;; --port) PORT="$2"; shift 2;; --tests) TESTS="$2"; shift 2;;
    --server-cpus) SERVER_CPUS="$2"; shift 2;; --wrk-cpus) WRK_CPUS="$2"; shift 2;; --duration) DURATION="$2"; shift 2;;
    --levels) LEVELS="$2"; shift 2;; --pipeline-levels) PIPELINE_LEVELS="$2"; shift 2;; --query-levels) QUERY_LEVELS="$2"; shift 2;;
    --max-concurrency) MAX_CONCURRENCY="$2"; shift 2;; --out) OUT="$2"; shift 2;;
    --) shift; break;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[[ -z "$NAME" || -z "$PORT" || -z "$TESTS" || $# -eq 0 ]] && { echo "missing --name/--port/--tests or server command" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/../results/$NAME}"; mkdir -p "$OUT"
WRK_THREADS=$(taskset -c "$WRK_CPUS" nproc)
HOST="127.0.0.1:$PORT"
SUMMARY="$OUT/summary.csv"
echo "impl,test,level,rps,latency_avg_ms,latency_p99_ms,requests,errors,non2xx,transfer_mb_s" > "$SUMMARY"

# inode(s) of sockets LISTENing on $PORT, from /proc/net/tcp{,6}
listen_inodes() { awk -v port="$(printf '%04X' "$PORT")" '$4=="0A" && $2 ~ (":" port "$") {print $10}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; }
if [[ -n "$(listen_inodes)" ]]; then
  echo "[$NAME] ERROR: port $PORT is already in use (socket inode(s): $(listen_inodes | tr '\n' ' '))" >&2; exit 1
fi
echo "[$NAME] starting server (cpus $SERVER_CPUS): $*"
taskset -c "$SERVER_CPUS" "$@" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 150); do
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "[$NAME] ERROR: server exited during startup:" >&2; cat "$OUT/server.log" >&2; exit 1; }
  curl -sf -o /dev/null "http://$HOST/plaintext" || curl -sf -o /dev/null "http://$HOST/db" && break; sleep 0.2
done
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || { echo "[$NAME] ERROR: server not running" >&2; cat "$OUT/server.log" >&2; exit 1; }
# the pid we own must be the one listening
# (grep without -q: with pipefail, an early-exiting grep would SIGPIPE ls and fail the check spuriously)
owned=0; for ino in $(listen_inodes); do [[ -n "$(ls -l "/proc/$SERVER_PID/fd" 2>/dev/null | grep "socket:\[$ino\]")" ]] && owned=1; done
[[ $owned -eq 1 ]] || { echo "[$NAME] ERROR: listener on :$PORT is not our server (pid $SERVER_PID)" >&2; exit 1; }

wrk_run() { # wrk_run <file> <extra wrk args...>
  local file="$1"; shift
  taskset -c "$WRK_CPUS" wrk -H "Host: $HOST" -H "Accept: $ACCEPT" -H "Connection: keep-alive" --latency --timeout 8 "$@" | tee "$file"
}
to_ms() { # value with unit -> ms
  awk -v v="$1" 'BEGIN{ if (v ~ /us$/) printf "%.3f", substr(v,1,length(v)-2)/1000; else if (v ~ /ms$/) printf "%.3f", substr(v,1,length(v)-2); else if (v ~ /s$/) printf "%.3f", substr(v,1,length(v)-1)*1000; else printf "%s", v }'
}
record() { # record <test> <level> <file>
  local rps avg p99 reqs err non2xx tx
  rps=$(awk '/Requests\/sec/{print $2}' "$3")
  avg=$(to_ms "$(awk '/^ *Latency/{print $2; exit}' "$3")")
  p99=$(to_ms "$(awk '/^ *99%/{print $2}' "$3")")
  reqs=$(awk '/requests in/{print $1}' "$3")
  err=$(awk '/Socket errors/{gsub(",","",$0); print $4+$6+$8+$10}' "$3"); err=${err:-0}
  non2xx=$(awk '/Non-2xx/{print $NF}' "$3"); non2xx=${non2xx:-0}
  tx=$(awk '/Transfer\/sec/{v=$2; if (v ~ /KB$/) printf "%.3f", substr(v,1,length(v)-2)/1024; else if (v ~ /MB$/) printf "%.3f", substr(v,1,length(v)-2); else if (v ~ /GB$/) printf "%.3f", substr(v,1,length(v)-2)*1024; else print v}' "$3")
  echo "$NAME,$1,$2,$rps,$avg,$p99,$reqs,$err,$non2xx,$tx" >> "$SUMMARY"
}
threads_for() { local c=$1; echo $(( c > WRK_THREADS ? WRK_THREADS : c )); }

for test in $TESTS; do
  case "$test" in
    plaintext) URL="/plaintext"; ACCEPT="text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7";;
    json)      URL="/json";      ACCEPT="application/json,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7";;
    db)        URL="/db";        ACCEPT="application/json,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7";;
    fortunes)  URL="/fortunes";  ACCEPT="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";;
    queries)   URL="/queries?q="; ACCEPT="application/json,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7";;
    updates)   URL="/updates?q="; ACCEPT="application/json,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7";;
    *) echo "unknown test $test" >&2; exit 2;;
  esac
  echo; echo "################ [$NAME] $test ################"
  case "$test" in
    queries|updates)
      echo "--- primer";  wrk_run "$OUT/$test-primer.txt" -d 5 -c 8 -t 8 "http://$HOST${URL}2" >/dev/null; sleep 3
      echo "--- warmup";  wrk_run "$OUT/$test-warmup.txt" -d "$DURATION" -c "$MAX_CONCURRENCY" -t "$WRK_THREADS" "http://$HOST${URL}2" >/dev/null; sleep 3
      for q in $QUERY_LEVELS; do
        echo "--- queries=$q (c=$MAX_CONCURRENCY)"
        wrk_run "$OUT/$test-$q.txt" -d "$DURATION" -c "$MAX_CONCURRENCY" -t "$WRK_THREADS" "http://$HOST${URL}$q"
        record "$test" "$q" "$OUT/$test-$q.txt"; sleep 2
      done;;
    plaintext)
      echo "--- primer";  wrk_run "$OUT/$test-primer.txt" -d 5 -c 8 -t 8 "http://$HOST$URL" >/dev/null; sleep 3
      echo "--- warmup";  wrk_run "$OUT/$test-warmup.txt" -d "$DURATION" -c "$MAX_CONCURRENCY" -t "$WRK_THREADS" "http://$HOST$URL" >/dev/null; sleep 3
      for c in $PIPELINE_LEVELS; do
        echo "--- concurrency=$c pipeline=$PIPELINE"
        wrk_run "$OUT/$test-$c.txt" -d "$DURATION" -c "$c" -t "$(threads_for "$c")" "http://$HOST$URL" -s "$HERE/pipeline.lua" -- "$PIPELINE"
        record "$test" "$c" "$OUT/$test-$c.txt"; sleep 2
      done;;
    *)
      echo "--- primer";  wrk_run "$OUT/$test-primer.txt" -d 5 -c 8 -t 8 "http://$HOST$URL" >/dev/null; sleep 3
      echo "--- warmup";  wrk_run "$OUT/$test-warmup.txt" -d "$DURATION" -c "$MAX_CONCURRENCY" -t "$WRK_THREADS" "http://$HOST$URL" >/dev/null; sleep 3
      for c in $LEVELS; do
        echo "--- concurrency=$c"
        wrk_run "$OUT/$test-$c.txt" -d "$DURATION" -c "$c" -t "$(threads_for "$c")" "http://$HOST$URL"
        record "$test" "$c" "$OUT/$test-$c.txt"; sleep 2
      done;;
  esac
done
echo; echo "[$NAME] done -> $SUMMARY"; cat "$SUMMARY"
