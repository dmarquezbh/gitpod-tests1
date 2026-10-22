# Resultados: Rust (axum) vs .NET 11 (Kestrel e platform) vs Go (net/http e fasthttp)

Data: 2026-10-22. Metodologia, arquitetura e reprodução em [`README.md`](README.md). Saída bruta do
`wrk` por nível em `results/<implementação>/`. Todas as cinco implementações rodaram a mesma suíte
(scripts `wrk` do TechEmpower), na mesma máquina, no mesmo PostgreSQL, na mesma sessão.

## Resumo (melhor nível por teste, critério de ranking do TechEmpower)

| Teste | Rust axum | .NET 11 Kestrel | **.NET 11 Platform** | Go net/http | Go fasthttp | Vencedor |
|---|---:|---:|---:|---:|---:|---|
| plaintext (pipelined x16) | 818.902 | 938.703 (1,15x) | **2.441.173 (2,98x)** | 104.093 | 950.440 | .NET Platform |
| json | 225.100 | 140.658 (0,62x) | **283.393 (1,26x)** | 77.578 | 179.528 | .NET Platform |
| db (1 SELECT) | **128.029** | 73.306 (0,57x) | 115.646 (0,90x) | 29.754 | 31.971 | Rust |
| queries q=1 | 112.343 | 73.941 | 111.969 (1,00x) | 25.207 | 29.727 | empate Rust / .NET Platform |
| queries q=20 | 8.063 | **21.633 (2,68x)** | 15.882 (1,97x) | 2.713 | 2.811 | .NET (as duas) |
| fortunes | 94.869 | 68.537 (0,72x) | 95.011 (1,00x) | 16.508 | 27.098 | empate Rust / .NET Platform |
| updates q=1 | 20.790 | **23.373 (1,12x)** | 18.781 (0,90x) | 10.620 | 17.426 | .NET Kestrel |
| updates q=20 | 4.318 | **9.054 (2,10x)** | 6.171 (1,43x) | 1.438 | 2.394 | .NET (as duas) |

Leitura honesta do quadro:

- **.NET 11 vence ou empata com o Rust em 6 das 8 linhas**, e por margens grandes onde vence
  (plaintext 3x, json 1,26x, queries/updates com várias consultas 2x–2,7x).
- **Rust continua à frente em `/db` (≈10%) e `/updates q=1` (≈10%)** na variante platform. Nas
  rodadas curtas de tuning o `/db` do .NET chegou a 113k contra ~120k do Rust; a diferença é da
  ordem do ruído entre rodadas (±5–10%), mas foi consistente em todas as execuções, então não
  está sendo contada como empate. A hipótese do pedido ("o .NET bate o Rust em todas as categorias")
  **não se confirmou integralmente** nesta máquina: ficou a ~10% em duas delas.
- O que separa as duas variantes .NET é a camada HTTP e a camada de banco, não a aplicação: o
  mesmo JSON, o mesmo SQL e o mesmo renderizador de fortunes estão nas duas.
- As duas versões Go (código do próprio TechEmpower, sem ajuste) ficaram bem atrás em todos os
  testes de banco (pool pgx sem pipelining, uma ida ao banco por consulta); o fasthttp empata com o
  Rust em plaintext e fica a 20% em json; o net/http é fraco em pipelining (plaintext ~100k).
- Nenhum erro de socket, timeout ou resposta não-2xx em nenhum nível, em nenhuma implementação.

## Tabela completa

| Test | Level | Rust axum req/s | .NET Kestrel req/s (vs Rust axum) | .NET Platform req/s (vs Rust axum) | Go net/http req/s (vs Rust axum) | Go fasthttp req/s (vs Rust axum) | avg / p99 ms (Rust axum · .NET Kestrel · .NET Platform · Go net/http · Go fasthttp) | errors |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| plaintext | c=256 (x16) | 799,466 | 938,703 (1.17x) | 2,440,595 (3.05x) | 93,165 (0.12x) | 950,440 (1.19x) | 3.0 / 13.9 · 2.6 / 8.9 · 0.8 / 5.7 · 47.1 / 174.8 · 2.9 / 8.5 | 0 / 0 / 0 / 0 / 0 |
| plaintext | c=1024 (x16) | 818,902 | 904,950 (1.11x) | 2,441,173 (2.98x) | 103,541 (0.13x) | 922,887 (1.13x) | 10.9 / 0.0 · 10.2 / 0.0 · 2.2 / 7.5 · 102.4 / 308.9 · 9.9 / 22.4 | 0 / 0 / 0 / 0 / 0 |
| plaintext | c=4096 (x16) | 757,323 | 787,121 (1.04x) | 1,978,170 (2.61x) | 104,093 (0.14x) | 785,198 (1.04x) | 45.3 / 0.0 · 42.5 / 0.0 · 11.4 / 39.8 · 349.9 / 687.3 · 45.5 / 99.5 | 0 / 0 / 0 / 0 / 0 |
| json | c=16 | 200,641 | 83,422 (0.42x) | 239,124 (1.19x) | 61,822 (0.31x) | 112,371 (0.56x) | 0.1 / 2.4 · 0.4 / 4.0 · 0.2 / 2.3 · 0.5 / 4.3 · 0.4 / 4.1 | 0 / 0 / 0 / 0 / 0 |
| json | c=64 | 225,100 | 123,992 (0.55x) | 283,393 (1.26x) | 76,251 (0.34x) | 177,402 (0.79x) | 0.3 / 2.5 · 0.6 / 3.3 · 0.2 / 1.6 · 1.1 / 5.9 · 0.4 / 2.7 | 0 / 0 / 0 / 0 / 0 |
| json | c=256 | 223,004 | 140,658 (0.63x) | 272,952 (1.22x) | 77,578 (0.35x) | 179,528 (0.81x) | 1.1 / 4.5 · 1.8 / 5.5 · 0.9 / 4.6 · 3.5 / 11.2 · 1.4 / 4.1 | 0 / 0 / 0 / 0 / 0 |
| json | c=512 | 218,733 | 138,862 (0.63x) | 276,004 (1.26x) | 76,576 (0.35x) | 174,147 (0.80x) | 2.3 / 6.4 · 3.6 / 8.7 · 1.6 / 4.9 · 6.8 / 19.1 · 3.0 / 7.4 | 0 / 0 / 0 / 0 / 0 |
| db | c=16 | 61,561 | 35,400 (0.58x) | 60,458 (0.98x) | 29,754 (0.48x) | 31,896 (0.52x) | 0.7 / 10.9 · 0.6 / 4.1 · 0.6 / 6.1 · 0.7 / 4.5 · 0.8 / 5.1 | 0 / 0 / 0 / 0 / 0 |
| db | c=64 | 103,607 | 52,418 (0.51x) | 89,389 (0.86x) | 27,694 (0.27x) | 31,580 (0.30x) | 0.7 / 3.5 · 1.7 / 9.4 · 1.7 / 40.3 · 2.9 / 13.6 · 2.3 / 8.0 | 0 / 0 / 0 / 0 / 0 |
| db | c=256 | 117,365 | 67,517 (0.58x) | 108,510 (0.92x) | 28,354 (0.24x) | 31,971 (0.27x) | 2.2 / 8.9 · 3.7 / 12.2 · 2.5 / 11.1 · 12.3 / 59.7 · 8.2 / 22.2 | 0 / 0 / 0 / 0 / 0 |
| db | c=512 | 128,029 | 73,306 (0.57x) | 115,646 (0.90x) | 28,959 (0.23x) | 31,436 (0.25x) | 3.8 / 11.3 · 6.8 / 21.4 · 4.5 / 20.1 · 24.2 / 117.9 · 16.4 / 38.6 | 0 / 0 / 0 / 0 / 0 |
| queries | q=1 | 112,343 | 73,941 (0.66x) | 111,969 (1.00x) | 25,207 (0.22x) | 29,727 (0.26x) | 4.4 / 12.3 · 7.0 / 24.3 · 4.7 / 29.0 · 28.8 / 145.8 · 17.5 / 45.5 | 0 / 0 / 0 / 0 / 0 |
| queries | q=5 | 26,139 | 42,798 (1.64x) | 52,748 (2.02x) | 8,462 (0.32x) | 9,672 (0.37x) | 20.5 / 63.3 · 11.7 / 32.6 · 9.7 / 20.6 · 71.1 / 298.7 · 59.6 / 233.6 | 0 / 0 / 0 / 0 / 0 |
| queries | q=10 | 18,037 | 31,199 (1.73x) | 31,481 (1.75x) | 4,947 (0.27x) | 5,486 (0.30x) | 28.6 / 74.4 · 16.2 / 40.6 · 16.2 / 28.8 · 119.9 / 497.3 · 105.5 / 422.4 | 0 / 0 / 0 / 0 / 0 |
| queries | q=20 | 8,063 | 21,633 (2.68x) | 15,882 (1.97x) | 2,714 (0.34x) | 2,812 (0.35x) | 63.4 / 139.4 · 24.3 / 80.8 · 32.1 / 48.2 · 216.6 / 907.9 · 207.0 / 846.1 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=16 | 63,537 | 33,192 (0.52x) | 56,934 (0.90x) | 16,508 (0.26x) | 26,942 (0.42x) | 0.3 / 3.1 · 0.7 / 4.6 · 0.5 / 5.9 · 1.1 / 5.6 · 0.8 / 5.0 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=64 | 80,920 | 46,549 (0.58x) | 83,950 (1.04x) | 15,986 (0.20x) | 25,059 (0.31x) | 0.8 / 4.0 · 1.5 / 7.2 · 1.0 / 10.5 · 5.0 / 22.5 · 4.3 / 65.9 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=256 | 94,869 | 61,167 (0.64x) | 93,641 (0.99x) | 16,181 (0.17x) | 27,098 (0.29x) | 2.6 / 6.7 · 4.2 / 13.3 · 2.9 / 18.4 · 21.2 / 101.5 · 9.6 / 25.9 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=512 | 92,562 | 68,537 (0.74x) | 95,011 (1.03x) | 15,783 (0.17x) | 26,830 (0.29x) | 5.3 / 12.4 · 7.3 / 17.8 · 6.5 / 73.8 · 43.8 / 213.9 · 19.4 / 50.5 | 0 / 0 / 0 / 0 / 0 |
| updates | q=1 | 20,790 | 23,373 (1.12x) | 18,781 (0.90x) | 10,620 (0.51x) | 17,426 (0.84x) | 24.5 / 42.2 · 22.1 / 65.8 · 27.1 / 38.5 · 55.6 / 227.6 · 31.7 / 111.9 | 0 / 0 / 0 / 0 / 0 |
| updates | q=5 | 11,894 | 17,386 (1.46x) | 11,995 (1.01x) | 4,438 (0.37x) | 7,631 (0.64x) | 42.8 / 65.5 · 29.6 / 79.0 · 42.4 / 60.9 · 132.1 / 537.8 · 75.5 / 300.6 | 0 / 0 / 0 / 0 / 0 |
| updates | q=10 | 6,920 | 13,327 (1.93x) | 9,521 (1.38x) | 2,693 (0.39x) | 4,422 (0.64x) | 73.2 / 120.8 · 38.5 / 94.2 · 53.5 / 75.8 · 216.0 / 897.8 · 131.5 / 537.8 | 0 / 0 / 0 / 0 / 0 |
| updates | q=20 | 4,318 | 9,054 (2.10x) | 6,171 (1.43x) | 1,438 (0.33x) | 2,395 (0.55x) | 117.5 / 176.1 · 56.8 / 145.6 · 82.3 / 128.4 · 399.8 / 1680.0 · 240.1 / 964.0 | 0 / 0 / 0 / 0 / 0 |

**Melhor nível por teste (critério de ranking do TechEmpower):**

| Test | Rust axum | .NET Kestrel | .NET Platform | Go net/http | Go fasthttp |
|---|---:|---:|---:|---:|---:|
| plaintext | 818,902 | 938,703 (1.15x) | 2,441,173 (2.98x) | 104,093 (0.13x) | 950,440 (1.16x) |
| json | 225,100 | 140,658 (0.62x) | 283,393 (1.26x) | 77,578 (0.34x) | 179,528 (0.80x) |
| db | 128,029 | 73,306 (0.57x) | 115,646 (0.90x) | 29,754 (0.23x) | 31,971 (0.25x) |
| queries | 112,343 | 73,941 (0.66x) | 111,969 (1.00x) | 25,207 (0.22x) | 29,727 (0.26x) |
| fortunes | 94,869 | 68,537 (0.72x) | 95,011 (1.00x) | 16,508 (0.17x) | 27,098 (0.29x) |
| updates | 20,790 | 23,373 (1.12x) | 18,781 (0.90x) | 10,620 (0.51x) | 17,426 (0.84x) |

> Latências p99 "0.0" no plaintext são um artefato conhecido do `wrk` com pipelining (o histograma
> não é confiável nesse modo); o TechEmpower tem o mesmo artefato.

## Ambiente

| Item | Valor |
|---|---|
| Máquina | 4 vCPU Intel Xeon @ 2.10GHz, 15 GiB RAM, Linux 6.18 (container cloud) |
| Pinning | servidor em CPUs 0-1 (`taskset`), `wrk` em CPUs 2-3 (2 threads); PostgreSQL livre nas 4 |
| Carga | `wrk 4.1.0`, mesmos cabeçalhos/durações dos scripts `toolset/wrk` do TFB; 10 s por nível (TFB: 15 s), primer 5 s + warmup |
| Níveis | json/db/fortunes: c = 16, 64, 256, 512 · plaintext: c = 256, 1024, 4096 (pipeline 16) · queries/updates: q = 1, 5, 10, 20 em c = 512 |
| Rust | rustc 1.97.0, axum 0.8.7, hyper 1.8.1, tokio 1.48, tokio-postgres 0.7.15, mimalloc; `--release`, LTO fat, `target-cpu=native` |
| .NET Kestrel | SDK 11.0.100-rc.2, Kestrel HTTP/1 only, Npgsql 10.0.3 (4 data sources × pool 2, multiplexing), System.Text.Json source-gen; Server GC sem DATAS, PGO dinâmico, `DOTNET_ReadyToRun=0`, runtime-async |
| .NET Platform | mesmo SDK; loop HTTP/1.1 próprio sobre `Socket`; cliente PostgreSQL próprio (2 conexões, pipelined, binário, Nagle ligado); GC workstation não-concorrente, gen0 64 MB; runtime-async |
| Go | go 1.24.7, `GOAMD64=v3`; go-std: net/http + jackc/pgx v3 (pool 8); fasthttp 1.60 + pgx v4 pool (8) |
| Banco | PostgreSQL 16.15 local, `synchronous_commit=off`, `max_connections=2000` e demais ajustes de `tools/tfb-postgresql.conf` |

Todos os servidores enxergam 2 CPUs (axum: 2 runtimes Tokio *current-thread*, 1 conexão PG cada;
Go: `GOMAXPROCS=2`; .NET: 2 threads de IO com *inline completions*).

Ressalvas: (1) máquina pequena e compartilhada: os números absolutos não se comparam aos do site do
TechEmpower, só as razões; (2) com 4 cores, PostgreSQL concorre por CPU com o servidor e com o `wrk`,
o que limita todos nos testes de banco; (3) uma execução por nível; a variação entre rodadas curtas
foi de ±5–10% (o Rust foi executado duas vezes, com diferenças dessa ordem); (4) o `wrk` com 2
threads é parte do gargalo no plaintext acima de ~2,5M req/s.

## Como o .NET chegou lá (rodadas curtas de 5 s, c=256 / q=20 / plaintext c=1024)

| Passo | plaintext | json | db | fortunes | queries q=20 | updates q=20 |
|---|---:|---:|---:|---:|---:|---:|
| Kestrel + Npgsql (1ª versão) | 903.465 | 131.070 | 67.800 | 60.670 | 19.579 | 7.468 |
| + inline completions (Kestrel) | 221.722 | 150.245 | 71.948 | 59.126 | 19.628 | 8.364 |
| Platform: HTTP próprio sobre transporte Kestrel, Npgsql | 2.499.256 | 202.972 | 76.387 | — | — | — |
| + Npgsql em 4 data sources × pool 2 | — | — | 86.984 | 69.662 | 20.208 | — |
| + cliente PostgreSQL próprio (2 conexões, afinidade por thread de IO) | — | — | 103.434 | 85.820 | 16.600 | 6.451 |
| + loop HTTP direto sobre `Socket` (sem Pipe) | 2.358.924 | 257.146 | 100.279 | 93.727 | 15.766 | 6.824 |
| + Nagle no socket PG, GC workstation, gen0 64 MB (**final**) | — | 295.628 | 113.079 | 99.860 | 15.712 | — |
| Referência: Rust axum (mesmas rodadas curtas / suíte) | ~870.000 | ~225.000 | ~120.000 | ~94.000 | ~8.300 | ~4.400 |

Caminhos testados e descartados (medidos, não supostos): `IOQueueCount=0` (json −25%); Npgsql sem
multiplexação (db −55%); adiar o `send` do cliente PG para outra thread (db −10%); 4–8 conexões PG
(ajuda queries/updates, derruba db e fortunes: menos backends = menos troca de contexto na máquina
pequena); Server GC (p99 do fortunes 3x pior que workstation em 2 CPUs).

Perfil de CPU (`dotnet-trace`) e medição de uso de CPU por processo foram o que apontou cada passo:
o Npgsql multiplexado deixava 0,8 core ocioso (fila única de escrita) e gastava 17,8 µs de CPU por
requisição em `/db`; o cliente próprio gasta 12 µs (Rust: 10,9 µs).

## O que o .NET 11 trouxe em relação ao .NET 10 (aplicado e medido)

- **Runtime Async** (`<Features>runtime-async=on</Features>`): ativado nas duas variantes. Na
  variante Kestrel a diferença ficou dentro do ruído (±5%): nesta carga o custo dominante não era a
  máquina de estados. Na variante platform o caminho `/db` usa `ValueTask` + `IValueTaskSource`
  com continuação inline, que já evitava a alocação que o runtime-async elimina.
- Melhorias automáticas que entram no caminho quente: escaping do `Utf8JsonWriter` com
  `SearchValues` (4x mais rápido, segundo o artigo oficial), `Random.Next` ~1,8x, ThreadPool com
  menos *fences* para itens pequenos, continuações sem captura de `ExecutionContext`, alocação em
  stack por escape analysis, eliminação de *bounds checks* em padrões `IndexOf` + acesso.
- Não há Npgsql 11 no NuGet (10.0.3 é a última estável); Kestrel e System.Text.Json vêm do
  shared framework 11.0 RC2.

## Observação sobre o Go

As duas implementações Go são as do próprio TechEmpower, sem ajuste. `net/http` é conhecidamente
fraco em pipelining (plaintext ~100k) e o `go-std` do TFB ainda formata JSON com `encoding/json`
e um `\n` final. O fasthttp empata com o Rust em plaintext e fica a ~20% em json, mas as duas
versões Go sofrem muito no banco: o pool pgx faz uma ida ao banco por consulta sem pipelining,
e em 2 CPUs isso custa 4x em `/db` e 3x em `/queries`.
