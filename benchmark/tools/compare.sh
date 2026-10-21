#!/usr/bin/env bash
# Joins two summary.csv files produced by run-suite.sh and prints a Markdown comparison.
# Usage: compare.sh <rust-summary.csv> <dotnet-summary.csv> [rust-label] [dotnet-label]
set -euo pipefail
A="$1"; B="$2"; LA="${3:-Rust (axum)}"; LB="${4:-.NET 11 (Kestrel)}"
awk -F, -v LA="$LA" -v LB="$LB" '
  FNR==1 { next }
  FILENAME==ARGV[1] { a_rps[$2","$3]=$4; a_avg[$2","$3]=$5; a_p99[$2","$3]=$6; a_err[$2","$3]=$8+$9; next }
  { key=$2","$3; b_rps[key]=$4; b_avg[key]=$5; b_p99[key]=$6; b_err[key]=$8+$9; if (!(key in seen)) { order[++n]=key; seen[key]=1 } }
  END {
    tests["plaintext"]=1; tests["json"]=2; tests["db"]=3; tests["queries"]=4; tests["fortunes"]=5; tests["updates"]=6
    printf "| Test | Level | %s req/s | %s req/s | .NET / Rust | %s avg / p99 (ms) | %s avg / p99 (ms) | errors (R / N) |\n", LA, LB, LA, LB
    print  "|---|---:|---:|---:|---:|---:|---:|---:|"
    # sort keys by test order then numeric level
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) {
      split(order[i],x,","); split(order[j],y,",")
      if (tests[x[1]] > tests[y[1]] || (tests[x[1]]==tests[y[1]] && x[2]+0 > y[2]+0)) { t=order[i]; order[i]=order[j]; order[j]=t }
    }
    for (i=1;i<=n;i++) {
      k=order[i]; split(k,p,",")
      lvl = (p[1]=="queries"||p[1]=="updates") ? "q=" p[2] : (p[1]=="plaintext" ? "c=" p[2] " (x16)" : "c=" p[2])
      ar=(k in a_rps)?a_rps[k]:0; br=b_rps[k]
      ratio = ar>0 ? sprintf("%.2fx", br/ar) : "n/a"
      printf "| %s | %s | %s | %s | %s | %s / %s | %s / %s | %s / %s |\n", p[1], lvl, fmt(ar), fmt(br), ratio, a_avg[k], a_p99[k], b_avg[k], b_p99[k], a_err[k]+0, b_err[k]+0
    }
    print ""
    print "**Best level per test (TechEmpower ranks by the best result across levels):**"; print ""
    printf "| Test | %s best req/s | %s best req/s | .NET / Rust |\n|---|---:|---:|---:|\n", LA, LB
    for (i=1;i<=n;i++) { k=order[i]; split(k,p,","); if (a_rps[k]+0 > ba[p[1]]+0) ba[p[1]]=a_rps[k]; if (b_rps[k]+0 > bb[p[1]]+0) bb[p[1]]=b_rps[k]; if (!(p[1] in ts)) { ts[p[1]]=1; to[++m]=p[1] } }
    for (i=1;i<=m;i++) { t=to[i]; printf "| %s | %s | %s | %.2fx |\n", t, fmt(ba[t]), fmt(bb[t]), (ba[t]>0? bb[t]/ba[t] : 0) }
  }
  function fmt(v,  s) { s=sprintf("%d", v+0.5); while (s ~ /[0-9]{4}/) sub(/[0-9]{3}$|[0-9]{3},/, ",&", s); gsub(/,,/, ",", s); return s }
' "$A" "$B"
