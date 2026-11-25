#!/usr/bin/env bash
# Repete a suíte de cada stack até 4 rodadas seguidas sem novo melhor (teto de 8).
set -uo pipefail
cd "$(dirname "$0")/.."
DURATION="${DURATION:-5}"
for stack in paulo-epoll php lua nim; do
  script="run-$stack.sh"
  [ -x "$script" ] || { echo "$stack: sem $script"; continue; }
  case "$stack" in paulo-epoll) porta=18091;; php) porta=18093;; lua) porta=18094;; nim) porta=18095;; *) porta=0;; esac
  melhor=0; sem=0; r=0
  while [ "$sem" -lt 4 ] && [ "$r" -lt 8 ]; do
    r=$((r + 1))
    [ "$porta" -gt 0 ] && fuser -k "$porta/tcp" >/dev/null 2>&1
    sleep 1
    echo "== $stack rodada $r (melhor acumulado $melhor, sem progresso $sem)"
    DURATION=$DURATION "./$script" >/dev/null 2>&1 || { echo "$stack rodada $r falhou"; break; }
    novo=$(awk -F, 'NR>1 {if ($4+0 > b[$2]) b[$2]=$4+0} END {s=0; for (t in b) s+=b[t]; printf "%.0f", s}' "results/$stack/summary.csv")
    if [ "${novo:-0}" -gt "$melhor" ]; then melhor=$novo; sem=0; else sem=$((sem + 1)); fi
    mkdir -p "results/hosts/i5-3317u-linux-x64/rodadas"; cp -a "results/$stack" "results/hosts/i5-3317u-linux-x64/rodadas/$stack-r$r"
  done
  echo "$stack: parou após $r rodadas (melhor soma $melhor, sem progresso $sem)"
done
