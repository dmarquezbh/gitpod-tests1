# Resultados: Rust (axum) vs .NET 11 (Kestrel) — suíte TechEmpower

Data: 2026-10-21. Metodologia e código em [`README.md`](README.md). Saída bruta do `wrk` em `results/`.

## Resumo

| Teste | Rust (axum) melhor req/s | .NET 11 melhor req/s | .NET / Rust | Vencedor |
|---|---:|---:|---:|---|
| plaintext (pipelined x16) | 871.609 | 997.139 | 1,14x | .NET |
| json | 243.160 | 134.648 | 0,55x | Rust |
| db (1 SELECT) | 125.278 | 70.684 | 0,56x | Rust |
| queries (q=1) | 109.742 | 68.520 | 0,62x | Rust |
| queries (q=20) | 8.660 | 20.647 | 2,38x | .NET |
| fortunes | 96.350 | 63.357 | 0,66x | Rust |
| updates (q=1) | 20.958 | 26.105 | 1,25x | .NET |
| updates (q=20) | 4.541 | 8.695 | 1,91x | .NET |

- **Rust vence com folga onde o custo é "uma requisição HTTP = uma resposta pequena"** (json, db,
  fortunes, queries q=1): ~1,5x a 1,8x mais throughput e metade da latência média. O custo fixo
  por requisição de Kestrel (features do `HttpContext`, cabeçalhos, `Date`, agendamento no thread
  pool) é maior que o de hyper com um runtime Tokio *current-thread* por core.
- **.NET vence no plaintext com pipelining** (+14% em c=256/1024; empate em c=4096), onde o custo por
  requisição é diluído em cada leitura de socket.
- **.NET vence por 1,5x–2,4x quando a requisição carrega várias consultas** (queries/updates com
  q≥5). A diferença vem do acesso ao banco, não do HTTP: o .NET envia os N `SELECT`s num único
  `NpgsqlBatch` (uma ida ao banco) sobre conexões multiplexadas; a variante `axum-pg` dispara N
  `query_one` via `FuturesUnordered` numa única conexão `tokio-postgres` por core, e nessa máquina
  isso escala pior conforme q cresce (q=20: 8,7k req/s = 173k linhas/s, contra 125k req/s em `/db`).
- Nenhum erro de socket, timeout ou resposta não-2xx em nenhum nível, nos dois lados.

## Tabela completa

| Test | Level | Rust (axum) req/s | .NET 11 (Kestrel) req/s | .NET / Rust | Rust (axum) avg / p99 (ms) | .NET 11 (Kestrel) avg / p99 (ms) | errors (R / N) |
|---|---:|---:|---:|---:|---:|---:|---:|
| plaintext | c=256 (x16) | 871,609 | 997,139 | 1.14x | 2.700 / 12.930 | 2.480 / 8.520 | 0 / 0 |
| plaintext | c=1024 (x16) | 806,432 | 913,506 | 1.13x | 10.470 / 0.000 | 10.030 / 0.000 | 0 / 0 |
| plaintext | c=4096 (x16) | 784,865 | 763,797 | 0.97x | 44.600 / 0.000 | 43.350 / 0.000 | 0 / 0 |
| json | c=16 | 232,003 | 83,545 | 0.36x | 0.113 / 1.700 | 0.369 / 4.110 | 0 / 0 |
| json | c=64 | 238,462 | 123,084 | 0.52x | 0.319 / 2.460 | 0.592 / 3.700 | 0 / 0 |
| json | c=256 | 237,329 | 134,648 | 0.57x | 1.100 / 4.190 | 1.900 / 5.340 | 0 / 0 |
| json | c=512 | 243,160 | 133,631 | 0.55x | 2.060 / 6.110 | 3.780 / 9.240 | 0 / 0 |
| db | c=16 | 63,909 | 34,000 | 0.53x | 0.400 / 3.970 | 0.663 / 4.630 | 0 / 0 |
| db | c=64 | 96,417 | 51,954 | 0.54x | 0.761 / 4.600 | 1.740 / 9.960 | 0 / 0 |
| db | c=256 | 125,278 | 62,554 | 0.50x | 2.020 / 7.270 | 3.950 / 11.820 | 0 / 0 |
| db | c=512 | 122,686 | 70,684 | 0.58x | 4.020 / 12.350 | 7.150 / 23.310 | 0 / 0 |
| queries | q=1 | 109,742 | 68,520 | 0.62x | 4.530 / 14.500 | 7.380 / 25.620 | 0 / 0 |
| queries | q=5 | 29,514 | 44,153 | 1.50x | 18.290 / 59.290 | 11.280 / 29.470 | 0 / 0 |
| queries | q=10 | 19,163 | 31,930 | 1.67x | 27.120 / 70.600 | 16.210 / 61.650 | 0 / 0 |
| queries | q=20 | 8,660 | 20,647 | 2.38x | 58.950 / 133.600 | 25.210 / 74.330 | 0 / 0 |
| fortunes | c=16 | 65,584 | 32,503 | 0.50x | 0.304 / 2.760 | 0.755 / 5.010 | 0 / 0 |
| fortunes | c=64 | 83,093 | 47,754 | 0.57x | 0.842 / 3.970 | 1.530 / 8.400 | 0 / 0 |
| fortunes | c=256 | 79,214 | 57,197 | 0.72x | 3.300 / 11.350 | 4.450 / 12.810 | 0 / 0 |
| fortunes | c=512 | 96,350 | 63,357 | 0.66x | 5.150 / 12.120 | 7.930 / 21.410 | 0 / 0 |
| updates | q=1 | 20,958 | 26,105 | 1.25x | 24.370 / 40.950 | 20.310 / 69.340 | 0 / 0 |
| updates | q=5 | 11,688 | 16,812 | 1.44x | 43.520 / 66.190 | 30.880 / 87.660 | 0 / 0 |
| updates | q=10 | 7,595 | 12,202 | 1.61x | 66.790 / 99.490 | 43.190 / 129.480 | 0 / 0 |
| updates | q=20 | 4,541 | 8,695 | 1.91x | 111.560 / 179.960 | 59.250 / 150.210 | 0 / 0 |

**Best level per test (TechEmpower ranks by the best result across levels):**

| Test | Rust (axum) best req/s | .NET 11 (Kestrel) best req/s | .NET / Rust |
|---|---:|---:|---:|
| plaintext | 871,609 | 997,139 | 1.14x |
| json | 243,160 | 134,648 | 0.55x |
| db | 125,278 | 70,684 | 0.56x |
| queries | 109,742 | 68,520 | 0.62x |
| fortunes | 96,350 | 63,357 | 0.66x |
| updates | 20,958 | 26,105 | 1.25x |

> Latências p99 "0.000" no plaintext são um artefato conhecido do `wrk` com pipelining
> (o histograma de latência não é confiável nesse modo); o TechEmpower tem o mesmo artefato.

## Ambiente

| Item | Valor |
|---|---|
| Máquina | 4 vCPU Intel Xeon @ 2.10GHz, 15 GiB RAM, Linux 6.18 (container cloud) |
| Pinning | servidor em CPUs 0-1 (`taskset`), `wrk` em CPUs 2-3 (2 threads); PostgreSQL livre nas 4 |
| Carga | `wrk 4.1.0`, mesmos cabeçalhos/durações dos scripts `toolset/wrk` do TFB; 10 s por nível (TFB: 15 s), primer 5 s + warmup |
| Níveis | json/db/fortunes: c = 16, 64, 256, 512 · plaintext: c = 256, 1024, 4096 (pipeline 16) · queries/updates: q = 1, 5, 10, 20 em c = 512 |
| Rust | rustc 1.97.0, axum 0.8.7, hyper 1.8.1, tokio 1.48, tokio-postgres 0.7.15, mimalloc; `--release`, LTO fat, `target-cpu=native` |
| .NET | SDK 11.0.100-rc.2, Kestrel (HTTP/1 only), Npgsql 10.0.3 (multiplexing, pool 4), System.Text.Json source-gen; Server GC, DATAS off, Dynamic PGO, `DOTNET_ReadyToRun=0` |
| Banco | PostgreSQL 16.15 local, `synchronous_commit=off`, `max_connections=2000` e demais ajustes de `tools/tfb-postgresql.conf` |

Os dois servidores enxergam 2 CPUs: o axum sobe 2 runtimes Tokio *current-thread* (1 conexão
Postgres cada); o .NET usa Server GC com 2 heaps e no máximo 4 conexões Postgres multiplexadas.

Ressalvas: (1) a máquina é pequena e compartilhada — os números absolutos não são comparáveis aos
do site do TechEmpower, só a razão entre os dois lados; (2) `wrk` com 2 threads é parte do gargalo
no plaintext (~900k–1M req/s), o que comprime a diferença nesse teste; (3) uma única execução por
nível; a variação observada entre rodadas curtas foi de ±5–8%.

## Tuning do .NET (rodadas curtas de 5 s, c=256 / q=20 / plaintext c=1024)

| Config | plaintext | json | db | fortunes | queries q=20 | updates q=20 |
|---|---:|---:|---:|---:|---:|---:|
| **inline completions off, pool 4 (usada)** | 903.465 | 131.070 | 67.800 | 60.670 | 19.579 | 7.468 |
| inline completions on, pool 4 | 221.722 | 150.245 | 71.948 | 59.126 | 19.628 | 8.364 |
| inline completions on, pool 16 | 241.472 | — | 60.764 | — | 18.785 | — |
| inline off, pool 4, `IOQueueCount=0` | 703.187 | 99.054 | 67.947 | — | — | — |

`DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1` (o que o TechEmpower usa nas entradas aspnetcore,
em máquinas de muitos cores) rende +15% em json e +12% em updates aqui, mas derruba o plaintext
pipelined em 4x com apenas 2 CPUs. Como a comparação exige uma configuração única por processo,
ficou desligado. Pool de 4 conexões (perto das 2 do Rust) superou 16 e 32 em `/db`.

## O que mais poderia aproximar o .NET nos testes de requisição única

- Entrada "Platform" do TFB (servidor HTTP próprio sobre `System.IO.Pipelines`, sem Kestrel) —
  foge do objetivo "reimplementar a aplicação web", mas é a única forma conhecida de igualar hyper
  no custo fixo por requisição.
- Em máquinas com ≥8 cores, `inline completions` ligado tende a ser melhor em todos os testes.
