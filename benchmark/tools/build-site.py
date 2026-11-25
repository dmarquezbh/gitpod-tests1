#!/usr/bin/env python3
"""Builds docs/index.html from results/*/summary.csv and results/metrics.csv."""
import csv
import html
import os

BENCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(BENCH)
RES = os.path.join(BENCH, "results")

# display order and labels
IMPLS = [
    ("rust", "Rust axum"),
    ("rust-tuned", "Rust axum-tuned"),
    ("rust-may-minihttp", "Rust may-minihttp"),
    ("dotnet", ".NET 11 Kestrel"),
    ("dotnet-platform", ".NET 11 platform"),
    ("go-std", "Go net/http"),
    ("go-fasthttp", "Go fasthttp"),
    ("java", "Java 25"),
    ("python", "CPython 3.14"),
    ("pypy", "PyPy 3.11"),
    ("graalpy", "GraalPy 3.11"),
    ("node", "Node 26"),
    ("bun", "Bun 1.4"),
    ("deno", "Deno 2.9"),
    ("ruby", "Ruby 3.2"),
    ("c", "C (gcc)"),
    ("cpp", "C++ (epoll)"),
    ("zero", "Zero C#"),
    ("paulo-uvloop", "py-platform uvloop 3.13"),
    ("paulo-epoll", "py-platform epoll 3.14"),
    ("paulo-epoll-jit", "py-platform epoll 3.14 + JIT"),
    ("paulo-uvloop-nofp", "py-platform uvloop sem fast path"),
    ("paulo-epoll-nofp", "py-platform epoll sem fast path"),
    ("php", "PHP 8.3 (nginx + php-fpm)"), ("lua", "LuaJIT 2.1"),
    ("nim", "Nim 1.6 (httpbeast + libpq)"), ("elixir", "Elixir 1.14 (Cowboy + Postgrex)"),
    ("julia", "Julia 1.13 (HTTP.jl + LibPQ)"), ("dart", "Dart 3 (dart:io)"),
    ("kotlin", "Kotlin/JVM 25"), ("pascal", "Pascal (FPC)"), ("delphi", "Delphi (FPC modo Delphi)"),
    ("zig", "Zig 0.17"), ("cobol", "COBOL (GnuCOBOL)"), ("brainfuck", "Brainfuck"),
]
TESTS = ["plaintext", "json", "db", "queries", "fortunes", "updates"]
TEST_LABEL = {
    "plaintext": "plaintext",
    "json": "json",
    "db": "db (1 SELECT)",
    "queries": "queries (N SELECTs)",
    "fortunes": "fortunes",
    "updates": "updates",
}


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
                if key not in best or rps > best[key][0]:
                    best[key] = (rps, row["level"], int(row["errors"]) + int(row["non2xx"]))
    return best


def metrics():
    path = os.path.join(RES, "metrics.csv")
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            out[row["impl"]] = row
    return out


def fmt(n):
    return f"{int(round(float(n))):,}".replace(",", ".")


def mb(n):
    return f"{float(n) / (1024 * 1024):.1f} MB".replace(".", ",")


def kb_or_mb(n):
    n = float(n)
    if n < 1024 * 1024:
        return f"{n / 1024:.0f} KB"
    return mb(n)


def _ranking(best):
    """For each test: impls ordered by rps desc, with ranks; plus wins per impl."""
    ranks = {}
    wins = {impl: [] for impl, _ in IMPLS}
    for test in TESTS:
        ranked = sorted(
            ((impl, best[(impl, test)][0]) for impl, _ in IMPLS if (impl, test) in best),
            key=lambda x: -x[1],
        )
        for pos, (impl, rps) in enumerate(ranked, 1):
            ranks[(impl, test)] = pos
            if pos == 1:
                wins[impl].append(test)
    return ranks, wins


def table_throughput(best):
    ranks, wins = _ranking(best)
    # stacks sorted by number of category wins, then by average rank, then plaintext
    def score(impl):
        rs = [ranks[(impl, t)] for t in TESTS if (impl, t) in ranks]
        avg = sum(rs) / len(rs) if rs else 99
        plain = best.get((impl, "plaintext"), (0,))[0]
        return (-len(wins[impl]), avg, -plain)

    order = sorted((impl for impl, _ in IMPLS if any((impl, t) in best for t in TESTS)), key=score)
    labels = dict(IMPLS)
    head = "".join(f"<th>{html.escape(TEST_LABEL[t])}</th>" for t in TESTS)
    rows = []
    for impl in order:
        cells = []
        for test in TESTS:
            v = best.get((impl, test))
            if not v:
                cells.append("<td class='na'>—</td>")
                continue
            rps, level, errs = v
            mark = " *" if errs else ""
            text = f"{fmt(rps)}{mark}"
            if ranks[(impl, test)] == 1:
                text = f"<strong>{text}</strong>"
            cells.append(f"<td title='nível {level}'>{text}</td>")
        highlight = ", ".join(TEST_LABEL[t].split(" (")[0] for t in wins[impl]) or "—"
        if wins[impl]:
            highlight = f"<strong>{highlight}</strong>"
        rows.append(f"<tr><th>{html.escape(labels[impl])}</th>{''.join(cells)}<td class='hl'>{highlight}</td></tr>")
    return (
        "<table><thead><tr><th>Stack (ordenado por vitórias)</th>"
        f"{head}<th>Destaques (1º lugar)</th></tr></thead><tbody>{''.join(rows)}</tbody></table>"
    )


def table_podium(best):
    rows = []
    for test in TESTS:
        ranked = sorted(
            ((impl, best[(impl, test)][0]) for impl, _ in IMPLS if (impl, test) in best),
            key=lambda x: -x[1],
        )[:3]
        labels = dict(IMPLS)
        cells = "".join(
            f"<td><strong>{html.escape(labels[impl])}</strong><br><span class='rps'>{fmt(rps)}</span></td>"
            for impl, rps in ranked
        )
        rows.append(f"<tr><th>{html.escape(TEST_LABEL[test])}</th>{cells}</tr>")
    return (
        "<table><thead><tr><th>Categoria</th><th>1º</th><th>2º</th><th>3º</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def table_footprint(met):
    labels = dict(IMPLS)
    order = sorted((x for x, _ in IMPLS if x in met), key=lambda i: float(met[i]["peak_rss_kb"] or 0))
    min_rss = min((float(met[i]["peak_rss_kb"]) for i in order if met[i]["peak_rss_kb"]), default=0)
    min_total = min((float(met[i]["total_bytes"]) for i in order), default=0)
    rows = []
    for impl in order:
        m = met[impl]
        rss_val = float(m["peak_rss_kb"] or 0)
        rss = f"{rss_val / 1024:.0f} MB" if rss_val else "—"
        if rss_val and rss_val == min_rss:
            rss = f"<strong>{rss}</strong>"
        total = kb_or_mb(m["total_bytes"])
        if float(m["total_bytes"]) == min_total:
            total = f"<strong>{total}</strong>"
        rows.append(
            "<tr>"
            f"<th>{html.escape(labels[impl])}</th>"
            f"<td>{rss}</td><td>{kb_or_mb(m['app_bytes'])}</td>"
            f"<td>{kb_or_mb(m['runtime_bytes'])}</td><td>{total}</td>"
            "</tr>"
        )
    return (
        "<table><thead><tr><th>Stack (por RSS)</th><th>RSS de pico</th><th>App</th>"
        "<th>Runtime/deps</th><th>Total</th></tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


def main():
    best = best_levels()
    met = metrics()
    doc = f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>gitpod-tests1 — benchmark poliglota estilo TechEmpower</title>
<style>
  :root {{ color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --muted:#666; --line:#ddd; --card:#f6f6f6; --accent:#0b6bcb; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#141414; --fg:#e8e8e8; --muted:#a0a0a0; --line:#333; --card:#1d1d1d; --accent:#6cb6ff; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }}
  main {{ max-width: 1080px; margin: 0 auto; padding: 32px 20px 80px; }}
  h1 {{ font-size: 2rem; line-height:1.15; margin: 0 0 .3em; }}
  h2 {{ margin-top: 2.2em; border-bottom:1px solid var(--line); padding-bottom:.25em; }}
  h3 {{ margin-top: 1.6em; }}
  p, li {{ color: var(--fg); }}
  .lead {{ color: var(--muted); font-size: 1.05rem; }}
  .stats {{ display:flex; flex-wrap:wrap; gap:12px; margin:24px 0; }}
  .stat {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 16px; min-width:150px; }}
  .stat b {{ display:block; font-size:1.45rem; }}
  .stat span {{ color:var(--muted); font-size:.85rem; }}
  .wrap {{ overflow-x:auto; border:1px solid var(--line); border-radius:10px; margin:16px 0; }}
  table {{ border-collapse: collapse; width:100%; font-size:.9rem; white-space:nowrap; }}
  th, td {{ padding:8px 10px; border-bottom:1px solid var(--line); text-align:right; }}
  thead th {{ position:sticky; top:0; background:var(--card); text-align:right; }}
  tbody th, thead th:first-child {{ text-align:left; }}
  tbody tr:last-child td, tbody tr:last-child th {{ border-bottom:0; }}
  .na {{ color:var(--muted); }}
  .hl {{ text-align:left; white-space:normal; }}
  .rps {{ color:var(--muted); font-size:.8rem; }}
  code {{ background:var(--card); padding:.1em .35em; border-radius:4px; font-size:.9em; }}
  pre {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; overflow:auto; }}
  a {{ color: var(--accent); }}
  .note {{ border-left:3px solid var(--accent); padding:.2em 0 .2em 14px; color:var(--muted); }}
  footer {{ margin-top:48px; color:var(--muted); font-size:.85rem; }}
</style>
</head>
<body>
<main>
  <h1>Um benchmark poliglota, na mesma máquina e no mesmo banco</h1>
  <p class="lead">17 implementações do mesmo conjunto de endpoints no estilo TechEmpower, sob o mesmo
  <code>wrk</code>, o mesmo PostgreSQL 16 e a mesma metodologia. O objetivo é comparar stacks e
  runtimes com o mesmo trabalho, incluindo o custo de RAM e o tamanho do artefato — não só req/s.</p>

  <div class="stats">
    <div class="stat"><b>18</b><span>implementações</span></div>
    <div class="stat"><b>6</b><span>testes por stack</span></div>
    <div class="stat"><b>~55k</b><span>req/s no /queries q=1 (C++)</span></div>
    <div class="stat"><b>78 KB</b><span>binário do Zero C#</span></div>
  </div>

  <h2>O que é medido</h2>
  <ul>
    <li><b>plaintext</b>: <code>Hello, World!</code> com HTTP pipelining 16;</li>
    <li><b>json</b>: serialização por requisição;</li>
    <li><b>db</b>: um <code>SELECT</code> aleatório em <code>world</code>;</li>
    <li><b>queries</b>: N <code>SELECT</code>s aleatórios (q = 1, 5, 10, 20);</li>
    <li><b>fortunes</b>: SELECT + ordenação + HTML com escaping;</li>
    <li><b>updates</b>: N <code>SELECT</code>s + UPDATE em lote.</li>
  </ul>

  <p>O servidor roda fixado em 2 CPUs (<code>taskset 0-1</code>) e o <code>wrk</code> em outras 2
  (<code>2-3</code>), 10 s por nível, com primer e warmup. Níveis: 16/64/256/512 conexões no
  plaintext também 256/1024/4096 com pipeline 16. Host: Intel i5-3317U (2 núcleos, 4 threads,
  Ivy Bridge, sem AVX2), 3 GB RAM, Linux. PostgreSQL 16 em Docker, <code>synchronous_commit=off</code>.</p>

  <h2>Resultados — melhor req/s por teste</h2>
  <p>Cada célula é o melhor nível daquela stack; o <code>title</code> mostra o nível. <b>*</b> indica
  erros de socket naquele nível (o valor é o melhor nível sem erro quando existe).</p>
  <div class="wrap">{table_throughput(best)}</div>

  <h3>Pódio por categoria</h3>
  <p>Os três primeiros de cada teste, na mesma rodada.</p>
  <div class="wrap">{table_podium(best)}</div>

  <h2>RAM e tamanho</h2>
  <p>RSS de pico é a soma de <code>VmHWM</code> da árvore de processos do servidor durante a suíte.
  “App” é o que se publica (binário, pasta publicada, <code>node_modules</code> + fonte);
  “Runtime/deps” é o que precisa existir na máquina (runtime, JRE, intérprete, libpq).</p>
  <div class="wrap">{table_footprint(met)}</div>

  <h2>A rodada do .NET 11</h2>
  <p>O .NET 11 platform saiu de ~14,3k req/s para <b>47,3k req/s em <code>/queries?q=1</code></b>
  (2,8× o Rust axum) e de ~2,1k para <b>5,4k em q=20</b>. O caminho foi:</p>
  <ul>
    <li><b>uma consulta por request</b>: <code>unnest($1::int[]) WITH ORDINALITY</code> substituiu N
    Bind/Execute separados (q ≥ 2);</li>
    <li><b>batching entre requests</b>: todos os <code>/db</code> e <code>/queries?q=1</code> vistos
    num ciclo de <code>epoll</code> viram um único SELECT com array (e um único Bind/Execute),
    com fallback escalar quando o lote tem 1 item;</li>
    <li><b>updates em uma ida</b>: o UPDATE com <code>UNNEST</code> deixou de ser precedido pelo
    SELECT (os valores novos são gerados no cliente);</li>
    <li><b>driver libpq (C) via P/Invoke</b> em todos os caminhos de banco, com arrays e pipeline
    mode: o parser linha-a-linha managed era o gargalo de fortunes e queries largas;</li>
    <li><b>batching entre requests</b>: todos os <code>/queries</code> de um chunk viram uma única
    consulta com os ids concatenados, e a tabela de fortunes é lida uma vez por rodada de
    <code>epoll</code> e distribuída aos requests pendentes;</li>
    <li><b>runtime async do .NET 11</b> ligado no Kestrel e no platform; PGO dinâmico, workstation GC
    e <code>ReadyToRun=0</code> mantidos;</li>
    <li>Kestrel com Npgsql: mesmas consultas por array/UNNEST, <code>q=10</code> de 3,1k → 6,4k,
    <code>q=20</code> de 1,75k → 5,7k, updates q=20 de 1,27k → 3,2k.</li>
  </ul>
  <p class="note">Sobre “trocar o driver”: o cliente de wire protocol próprio continua mais rápido
  que o Npgsql neste host para o caminho de leitura; o ganho real veio de <i>menos round-trips</i>
  (array + batching por ciclo de epoll), não de trocar a biblioteca.</p>

  <h2>Zero C#</h2>
  <p>O <a href="https://onurgumus.github.io/zero-csharp/">Zero C#</a>, fork do bflat que compila C#
  sem runtime nem GC, entrou com um servidor escrito só com <code>DllImport</code>
  (pthreads + epoll + libpq): <b>548k req/s</b> no plaintext, <b>58 MB</b> de RSS e <b>78 KB</b> de
  binário (+354 KB de libpq). Sem runtime, sem coletor, sem async.</p>

  <h2>Caveats</h2>
  <ul>
    <li>Testes de banco são limitados pelo PostgreSQL deste host (2 núcleos); compare dentro da mesma rodada.</li>
    <li>Java (HttpServer do JDK) acumulou erros de socket em níveis altos; Ruby usa WEBrick
    (thread por conexão); ambos são baselines honestos das bibliotecas padrão, não dos frameworks mais rápidos.</li>
    <li><b>C++</b> entra com epoll + libpq (mesmo desenho do .NET platform): vence todas as
    categorias medidas, mas <b>updates</b> ficou de fora — UPDATEs UNNEST concorrentes geram
    deadlocks no PostgreSQL neste host.</li>
    <li><b>GraalPy</b> não fecha a conta neste host: o fallback de <code>select()</code> limita a
    ~1024 descritores (a rodada foi limitada a 256 conexões) e o processo chegou a <b>4,2 GB de RSS</b>
    em 3 GB de RAM, com swap — os números são medidos, mas não representam o GraalPy em hardware adequado.</li>
    <li><b>PyPy</b> rodou a mesma app uvicorn e ficou <i>abaixo</i> do CPython 3.14: o JIT não compensa
    o custo de asyncio/threadpool neste workload, e o RSS foi ~650 MB contra ~220 MB do CPython.</li>
    <li>As stacks do repositório rodaram numa sessão; as adicionadas, em sessões adjacentes, sem carga concorrente.</li>
    <li>Portas remapeadas (18080–18094), Go em <code>GOAMD64=v1</code> (CPU sem AVX2), DB em
    <code>127.0.0.1</code> no lugar do hostname <code>tfb-database</code>.</li>
  </ul>

  <h2>Reproduzir</h2>
  <pre>git clone https://github.com/dmarquezbh/gitpod-tests1
cd gitpod-tests1 &amp;&amp; git checkout ccr-4e64bf0c-doya78
cd benchmark
./run-rust.sh; ./run-dotnet-platform.sh; ./run-go.sh
./run-java.sh; ./run-python.sh; ./run-pypy.sh; ./run-graalpy.sh
./run-node.sh; ./run-bun.sh; ./run-deno.sh; ./run-ruby.sh; ./run-c.sh; ./run-zero.sh</pre>

  <p>Dados brutos: <a href="https://github.com/dmarquezbh/gitpod-tests1/blob/ccr-4e64bf0c-doya78/benchmark/results/comparison.md">comparison.md</a>,
  <a href="https://github.com/dmarquezbh/gitpod-tests1/blob/ccr-4e64bf0c-doya78/benchmark/results/metrics.csv">metrics.csv</a>.</p>

  <footer>Gerado a partir de <code>benchmark/results/*/summary.csv</code> e <code>metrics.csv</code>.
  Benchmarks são do ambiente descrito; números absolutos não se transferem para outro hardware.</footer>
</main>
</body>
</html>
"""
    outdir = os.path.join(ROOT, "docs")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "static.html"), "w") as f:
        f.write(doc)
    print("wrote docs/static.html")


if __name__ == "__main__":
    main()
