# Rust (axum) vs .NET 11 (Kestrel) — TechEmpower-style benchmark

Reimplementação em **.NET 11** da aplicação web Rust usada no
[TechEmpower FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks)
(`frameworks/Rust/axum`, variantes `axum` e `axum-pg`), executando **a mesma suíte de
benchmark** (os scripts `wrk` do próprio TechEmpower) contra as duas implementações.

Ver [`RESULTS.md`](RESULTS.md) para os números.

## Layout

| Caminho | Conteúdo |
|---|---|
| `rust-axum/` | Cópia literal da implementação Rust (commit em `UPSTREAM.txt`, licença em `LICENSE-TFB`). Não foi alterada. |
| `dotnet/` | Reimplementação em C# / .NET 11 (Kestrel + Npgsql). |
| `tools/run-suite.sh` | Réplica de `toolset/wrk/{concurrency,pipeline,query}.sh` do TFB, sem Docker, com pinning de CPU. |
| `tools/compare.sh` | Junta os dois `summary.csv` e gera as tabelas Markdown. |
| `tools/create-postgres.sql`, `tools/tfb-postgresql.conf` | Schema e tuning do PostgreSQL do TFB. |
| `run-rust.sh`, `run-dotnet.sh` | Compilam e rodam a suíte completa para cada lado. |
| `results/` | Saída bruta do `wrk` por nível + `summary.csv` por implementação. |

## Os seis testes (regras do TechEmpower)

| Teste | URL | O que faz |
|---|---|---|
| plaintext | `/plaintext` | `Hello, World!` em `text/plain`, HTTP pipelining profundidade 16 |
| json | `/json` | `{"message":"Hello, World!"}` serializado por requisição |
| db | `/db` | 1 `SELECT` de linha aleatória em `world` (10.000 linhas) |
| queries | `/queries?q=N` | N `SELECT`s separados (N limitado a 1..500; inválido → 1) |
| fortunes | `/fortunes` | `SELECT * FROM fortune`, adiciona uma linha em memória, ordena por mensagem, renderiza HTML com escaping |
| updates | `/updates?q=N` | N `SELECT`s + 1 `UPDATE` em lote (`UNNEST` de arrays, como no Rust) |

## Como a implementação .NET foi feita (foco em throughput)

- **Kestrel + um único middleware terminal** (`app.Run`) que faz `switch` no path. Sem roteamento,
  sem DI por requisição, sem model binding. Equivalente ao `Router` do axum sobre hyper.
- **HTTP/1 apenas**, `SO_BACKLOG` 4096, `UnsafePreferInlineScheduling` (continuações de socket na
  própria thread de IO; o Rust faz o mesmo com um runtime Tokio *current-thread* por core).
- **JSON com source generator** (`System.Text.Json`), `Utf8JsonWriter` reutilizado por thread
  (`[ThreadStatic]`), escrevendo em buffer reutilizável para emitir sempre `Content-Length`
  (sem *chunked encoding*).
- **Npgsql 10 com multiplexação** (`Multiplexing=true`) e *auto-prepare*; `/queries` e `/updates`
  enviam os N `SELECT`s como um único `NpgsqlBatch` (uma viagem ao banco), espelhando o
  pipelining do `tokio-postgres`. O `UPDATE` usa exatamente o mesmo SQL (`UNNEST($1::int[], $2::int[])`).
- **Fortunes**: renderizador HTML manual escrevendo UTF-8 direto no buffer, escaping idêntico
  ao do `yarte` (`&amp; &lt; &gt; &quot; &#x27; &#x2f;`) — a resposta é byte a byte igual à do Rust.
- Runtime: Server GC sem DATAS, PGO dinâmico, `DOTNET_ReadyToRun=0`, `InvariantGlobalization`.

## Como reproduzir

```bash
# pré-requisitos: rust toolchain, .NET 11 SDK, wrk, PostgreSQL 16 local
sudo -u postgres psql -c "CREATE USER benchmarkdbuser WITH PASSWORD 'benchmarkdbpass';"
sudo -u postgres psql -c "CREATE DATABASE hello_world OWNER benchmarkdbuser;"
sudo -u postgres psql -d hello_world -f tools/create-postgres.sql
# (opcional) aplicar tools/tfb-postgresql.conf ao postgresql.conf e reiniciar

./run-rust.sh      # -> results/rust/summary.csv
./run-dotnet.sh    # -> results/dotnet/summary.csv
tools/compare.sh results/rust/summary.csv results/dotnet/summary.csv
```
