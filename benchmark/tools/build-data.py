#!/usr/bin/env python3
"""Builds site/wwwroot/data.json for the Blazor report from results/*/summary.csv + metrics.csv."""
import csv, json, os

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
]
TESTS = [
    ("plaintext", "plaintext", "Hello, World! com pipelining 16"),
    ("json", "json", "JSON serializado por requisição"),
    ("db", "db", "1 SELECT aleatório"),
    ("queries", "queries", "N SELECTs aleatórios"),
    ("fortunes", "fortunes", "SELECT + ordenação + HTML escapado"),
    ("updates", "updates", "N SELECTs + UPDATE em lote"),
]

def best_levels():
    best = {}
    for impl, _ in IMPLS:
        path = os.path.join(RES, impl, "summary.csv")
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

def metrics():
    out = {}
    path = os.path.join(RES, "metrics.csv")
    if os.path.exists(path):
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                out[row["impl"]] = {
                    "rssKb": int(row["peak_rss_kb"] or 0),
                    "appBytes": int(row["app_bytes"]), "runtimeBytes": int(row["runtime_bytes"]),
                    "totalBytes": int(row["total_bytes"]),
                }
    return out

def host():
    path = os.path.join(RES, "host.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}

def main():
    best = best_levels()
    met = metrics()
    data = {
        "impls": [{"id": i, "label": l} for i, l in IMPLS],
        "tests": [
            {"id": tid, "label": label, "note": note,
             "results": [
                 {"impl": impl, "rps": round(best[(impl, tid)]["rps"], 2),
                  "level": best[(impl, tid)]["level"], "errors": best[(impl, tid)]["errors"]}
                 for impl, _ in IMPLS if (impl, tid) in best
             ]}
            for tid, label, note in TESTS
        ],
        "metrics": [{"impl": i, **met[i]} for i, _ in IMPLS if i in met],
        "host": host(),
    }
    with open(OUT, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"wrote {OUT}: {len(data['tests'])} tests, {len(data['metrics'])} metrics")

if __name__ == "__main__":
    main()
