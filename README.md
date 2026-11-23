# gitpod-tests1 — benchmark Rust vs .NET 11 vs Go

**Resultados publicados:** https://dmarquezbh.github.io/gitpod-tests1/ — 18 stacks, throughput,
RAM de pico e tamanho de artefato, com a metodologia completa.

**Relatório interativo (Blazor WASM):** https://dmarquezbh.github.io/gitpod-tests1/ — gráficos por
categoria, tabelas ordenáveis e RAM/tamanho; fallback sem JS em `static.html`.

**Manual de performance .NET 11:** [`benchmark/docs/dotnet-performance-playbook.md`](benchmark/docs/dotnet-performance-playbook.md)
— técnicas por categoria, medições e anti-padrões.

Este repositório contém uma pesquisa de desempenho no estilo TechEmpower: a aplicação web Rust (axum)
do TechEmpower reimplementada em .NET 11 de duas formas (Kestrel e um servidor "platform" com HTTP e
PostgreSQL próprios), comparada também com as implementações Go do TechEmpower, todas sob a mesma suíte
`wrk` e o mesmo PostgreSQL.

- [`RESULTS.md`](RESULTS.md) — resultados de todas as rodadas, todos os testes, todos os níveis.
- [`benchmark/README.md`](benchmark/README.md) — arquitetura das implementações, o que o .NET 11 muda, como reproduzir.
- [`benchmark/RESULTS.md`](benchmark/RESULTS.md) — relatório detalhado das rodadas 4 e 5 (perfil de CPU, tuning passo a passo).
- [`benchmark/docs/rodada-5.md`](benchmark/docs/rodada-5.md) — documentação completa da última rodada: o Rust melhorado (axum-tuned e may-minihttp) contra o .NET platform, com diff, validação, método, todos os níveis e análise.
- `benchmark/` — código das cinco implementações, scripts da suíte e saída bruta do `wrk`.

As pastas `benchmark/rust-axum`, `benchmark/go-std` e `benchmark/go-fasthttp` são cópias do
[TechEmpower FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks) (licença em `LICENSE-TFB`).
Os arquivos `.gitpod.*` são restos de testes antigos do Gitpod e não fazem parte do benchmark.
