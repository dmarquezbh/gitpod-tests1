#!/usr/bin/env python3
"""Builds site/wwwroot/data.json (multi-host) from results/*/summary.csv + metrics.csv.

Um host é a medição de uma máquina. A medição viva mora em ``benchmark/results/``; as
medições anteriores ficam em ``benchmark/results/hosts/<id>/`` (mesma estrutura). O publish
nunca apaga host: cada execução acrescenta/substitui apenas o host que acabou de rodar,
casado pelo ``host.id`` do ``host.json``.
"""
import csv
import json
import os

BENCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(BENCH, "results")
OUT = os.path.join(BENCH, "site", "wwwroot", "data.json")

IMPLS = [
    ("rust", "Rust axum"), ("rust-tuned", "Rust axum-tuned"),
    ("rust-may-minihttp", "Rust may-minihttp"), ("dotnet", ".NET 11 Kestrel"),
    ("dotnet-platform", ".NET 11 platform"), ("go-std", "Go net/http"),
    ("go-fasthttp", "Go fasthttp"), ("java", "Java 25"),
    ("python", "CPython 3.14"), ("pypy", "PyPy 3.11"), ("graalpy", "GraalPy 3.11"),
    ("node", "Node 26"), ("bun", "Bun 1.4"), ("deno", "Deno 2.9"),
    ("ruby", "Ruby 3.2"), ("c", "C (gcc)"), ("cpp", "C++ (epoll)"), ("zero", "Zero C#"),
    # PR #1 do Paulo: variantes "platform" em CPython (projeção: o PR só publicou razões).
    ("paulo-uvloop", "py-platform uvloop 3.13"), ("paulo-epoll", "py-platform epoll 3.14"),
    ("paulo-epoll-jit", "py-platform epoll 3.14 + JIT"),
    ("paulo-uvloop-nofp", "py-platform uvloop sem fast path"),
    ("paulo-epoll-nofp", "py-platform epoll sem fast path"),
    # Stacks implementadas nesta rodada multi-linguagem.
    ("php", "PHP 8.3 (nginx + php-fpm)"), ("lua", "LuaJIT 2.1"),
    ("nim", "Nim 1.6 (httpbeast + libpq)"), ("elixir", "Elixir 1.14 (Cowboy + Postgrex)"),
    ("julia", "Julia 1.13 (HTTP.jl + LibPQ)"), ("dart", "Dart 3 (dart:io)"),
    ("kotlin", "Kotlin/JVM 25"), ("pascal", "Pascal (FPC)"), ("delphi", "Delphi (FPC modo Delphi)"),
    ("zig", "Zig 0.17"), ("cobol", "COBOL (GnuCOBOL)"), ("brainfuck", "Brainfuck"),
]
TESTS = [
    ("plaintext", "plaintext", "Hello, World! com pipelining 16"),
    ("json", "json", "JSON serializado por requisição"),
    ("db", "db", "1 SELECT aleatório"),
    ("queries", "queries", "N SELECTs aleatórios"),
    ("fortunes", "fortunes", "SELECT + ordenação + HTML escapado"),
    ("updates", "updates", "N SELECTs + UPDATE em lote"),
]


def best_levels(res_dir):
    best = {}
    for impl, _ in IMPLS:
        path = os.path.join(res_dir, impl, "summary.csv")
        if not os.path.exists(path):
            continue
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                key = (impl, row["test"])
                rps = float(row["rps"])
                if key not in best or rps > best[key]["rps"]:
                    best[key] = {"rps": rps, "level": int(row["level"]),
                                 "errors": int(row["errors"]) + int(row["non2xx"])}
    return best


def metrics(res_dir):
    out = {}
    path = os.path.join(res_dir, "metrics.csv")
    if os.path.exists(path):
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                out[row["impl"]] = {
                    "rssKb": int(row["peak_rss_kb"] or 0),
                    "appBytes": int(row["app_bytes"]), "runtimeBytes": int(row["runtime_bytes"]),
                    "totalBytes": int(row["total_bytes"]),
                }
    return out


def host_info(res_dir):
    path = os.path.join(res_dir, "host.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def host_entry(res_dir):
    # Host com data.json pronto (projeção ou medição consolidada) não é recalculado.
    pronto = os.path.join(res_dir, "data.json")
    if os.path.exists(pronto):
        with open(pronto) as f:
            dados = json.load(f)
        return {"host": host_info(res_dir), "tests": dados.get("tests", []), "metrics": dados.get("metrics", [])}

    best = best_levels(res_dir)
    met = metrics(res_dir)
    return {
        "host": host_info(res_dir),
        "tests": [
            {"id": tid,
             "results": [
                 {"impl": impl, "rps": round(best[(impl, tid)]["rps"], 2),
                  "level": best[(impl, tid)]["level"], "errors": best[(impl, tid)]["errors"]}
                 for impl, _ in IMPLS if (impl, tid) in best
             ]}
            for tid, _, _ in TESTS
        ],
        "metrics": [{"impl": i, **met[i]} for i, _ in IMPLS if i in met],
    }


def score(entry):
    """Quanto mais resultados, mais completa a medição do host."""
    return sum(len(t["results"]) for t in entry["tests"])


def tem_medicao(path):
    return any(
        os.path.exists(os.path.join(path, impl, "summary.csv")) for impl, _ in IMPLS
    )


def hosts_arquivados():
    """Diretórios de hosts anteriores; aceita o layout correto e o aninhado por engano."""
    base = os.path.join(RES, "hosts")
    if not os.path.isdir(base):
        return []
    achados = []
    for nome in sorted(os.listdir(base)):
        caminho = os.path.join(base, nome)
        if not os.path.isdir(caminho):
            continue
        if os.path.exists(os.path.join(caminho, "host.json")) or tem_medicao(caminho):
            achados.append(caminho)
            continue
        # `cp -a . hosts/x/` dentro do próprio results criou hosts/x/x/
        for sub in sorted(os.listdir(caminho)):
            subcaminho = os.path.join(caminho, sub)
            if os.path.isdir(subcaminho) and (
                os.path.exists(os.path.join(subcaminho, "host.json")) or tem_medicao(subcaminho)
            ):
                achados.append(subcaminho)
    return achados


def main():
    candidatos = [host_entry(RES)] + [host_entry(p) for p in hosts_arquivados()]

    # Casa por host.id: a medição mais completa vence (medição arquivada contra a viva).
    escolhidos = {}
    for entrada in candidatos:
        host = entrada["host"]
        hid = host.get("id") or "sem-id"
        host["id"] = hid
        atual = escolhidos.get(hid)
        if atual is None or score(entrada) > score(atual):
            escolhidos[hid] = entrada

    hosts = sorted(
        escolhidos.values(),
        key=lambda e: (e["host"].get("date") or "", e["host"].get("id") or ""),
        reverse=True,
    )

    data = {
        "impls": [{"id": i, "label": l} for i, l in IMPLS],
        "tests": [{"id": tid, "label": label, "note": note} for tid, label, note in TESTS],
        "hosts": hosts,
    }
    with open(OUT, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)

    resumo = ", ".join(f"{h['host']['id']} ({score(h)} resultados)" for h in hosts)
    print(f"wrote {OUT}: {len(hosts)} host(s): {resumo}")


if __name__ == "__main__":
    main()
