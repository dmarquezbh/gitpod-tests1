#!/usr/bin/env bash
# Joins N summary.csv files produced by run-suite.sh and prints Markdown tables.
# The first file is the baseline; every other implementation gets a ratio against it.
# Usage: compare.sh "Label A=results/a/summary.csv" "Label B=results/b/summary.csv" [...]
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: compare.sh 'Label=summary.csv' 'Label=summary.csv' [...]" >&2; exit 2; }
labels=(); files=()
for arg in "$@"; do labels+=("${arg%%=*}"); files+=("${arg#*=}"); done
LABELS=$(IFS='|'; echo "${labels[*]}")
awk -F, -v LABELS="$LABELS" '
  BEGIN { n = split(LABELS, L, "|"); tests["plaintext"]=1; tests["json"]=2; tests["db"]=3; tests["queries"]=4; tests["fortunes"]=5; tests["updates"]=6 }
  FNR==1 { fi++; next }
  { key=$2","$3; rps[fi,key]=$4; avg[fi,key]=$5; p99[fi,key]=$6; err[fi,key]=$8+$9; if (!(key in seen)) { order[++m]=key; seen[key]=1 } }
  END {
    for (i=1;i<=m;i++) for (j=i+1;j<=m;j++) {
      split(order[i],x,","); split(order[j],y,",")
      if (tests[x[1]] > tests[y[1]] || (tests[x[1]]==tests[y[1]] && x[2]+0 > y[2]+0)) { t=order[i]; order[i]=order[j]; order[j]=t }
    }
    # ---- per-level table
    h = "| Test | Level | " L[1] " req/s |"; s = "|---|---:|---:|"
    for (f=2; f<=n; f++) { h = h " " L[f] " req/s (vs " L[1] ") |"; s = s "---:|" }
    h = h " avg / p99 ms (" ; for (f=1; f<=n; f++) h = h L[f] (f<n ? " · " : ""); h = h ") | errors |"; s = s "---|---:|"
    print h; print s
    for (i=1;i<=m;i++) {
      k=order[i]; split(k,p,",")
      lvl = (p[1]=="queries"||p[1]=="updates") ? "q=" p[2] : (p[1]=="plaintext" ? "c=" p[2] " (x16)" : "c=" p[2])
      base = rps[1,k]+0
      row = "| " p[1] " | " lvl " | " fmt(base) " |"
      for (f=2; f<=n; f++) row = row " " fmt(rps[f,k]) " (" (base>0 ? sprintf("%.2fx", rps[f,k]/base) : "n/a") ") |"
      lat = ""; e = ""
      for (f=1; f<=n; f++) { lat = lat sprintf("%.1f / %.1f", avg[f,k], p99[f,k]) (f<n ? " · " : ""); e = e (err[f,k]+0) (f<n ? " / " : "") }
      print row " " lat " | " e " |"
    }
    # ---- best-per-test table
    print ""; print "**Melhor nível por teste (critério de ranking do TechEmpower):**"; print ""
    h = "| Test | " L[1] " |"; s = "|---|---:|"
    for (f=2; f<=n; f++) { h = h " " L[f] " |"; s = s "---:|" }
    print h; print s
    for (i=1;i<=m;i++) { k=order[i]; split(k,p,","); for (f=1; f<=n; f++) if (rps[f,k]+0 > best[f,p[1]]+0) best[f,p[1]]=rps[f,k]; if (!(p[1] in ts)) { ts[p[1]]=1; to[++tn]=p[1] } }
    for (i=1;i<=tn;i++) {
      t=to[i]; row = "| " t " | " fmt(best[1,t]) " |"
      for (f=2; f<=n; f++) row = row " " fmt(best[f,t]) " (" (best[1,t]>0 ? sprintf("%.2fx", best[f,t]/best[1,t]) : "n/a") ") |"
      print row
    }
  }
  function fmt(v,  s) { s=sprintf("%d", v+0.5); while (s ~ /[0-9]{4}/) sub(/[0-9]{3}$|[0-9]{3},/, ",&", s); gsub(/,,/, ",", s); return s }
' "${files[@]}"
