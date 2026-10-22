# gitpod-tests1 — benchmark Rust vs .NET 11 vs Go

Este repositório contém uma pesquisa de desempenho no estilo TechEmpower: a aplicação web Rust (axum)
do TechEmpower reimplementada em .NET 11 de duas formas (Kestrel e um servidor "platform" com HTTP e
PostgreSQL próprios), comparada também com as implementações Go do TechEmpower, todas sob a mesma suíte
`wrk` e o mesmo PostgreSQL.

- [`RESULTS.md`](RESULTS.md) — resultados de todas as rodadas, todos os testes, todos os níveis.
- [`benchmark/README.md`](benchmark/README.md) — arquitetura das implementações, o que o .NET 11 muda, como reproduzir.
- [`benchmark/RESULTS.md`](benchmark/RESULTS.md) — relatório detalhado da última rodada (perfil de CPU, tuning passo a passo).
- `benchmark/` — código das cinco implementações, scripts da suíte e saída bruta do `wrk`.

As pastas `benchmark/rust-axum`, `benchmark/go-std` e `benchmark/go-fasthttp` são cópias do
[TechEmpower FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks) (licença em `LICENSE-TFB`).
Os arquivos `.gitpod.*` são restos de testes antigos do Gitpod e não fazem parte do benchmark.
