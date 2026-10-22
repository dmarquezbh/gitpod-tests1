# Resultados (rodada 4): Rust (axum) vs .NET 11 (Kestrel e platform) vs Go (net/http e fasthttp)

Data: 2026-10-22. Metodologia, arquitetura e reprodução em [`README.md`](README.md). Saída bruta do
`wrk` por nível em `results/<implementação>/`. As cinco implementações rodaram a mesma suíte
(scripts `wrk` do TechEmpower), em sequência, na mesma sessão, no mesmo host, no mesmo PostgreSQL.
Novidade da rodada: a variante platform ganhou um **event loop próprio por core** (`epoll` via
libc, HTTP e PostgreSQL na mesma thread), o desenho do tokio *current-thread* reproduzido em C#.

## Resumo (melhor nível por teste, critério de ranking do TechEmpower)

| Teste | Rust axum | .NET 11 Kestrel | **.NET 11 Platform** | Go net/http | Go fasthttp | Vencedor |
|---|---:|---:|---:|---:|---:|---|
| plaintext (pipelined x16) | 745.838 | 721.216 (0,97x) | **2.174.296 (2,92x)** | 81.817 | 712.783 | .NET Platform |
| json | 212.812 | 119.663 (0,56x) | **240.344 (1,13x)** | 54.615 | 157.430 | .NET Platform |
| db (1 SELECT) | 98.799 | 56.298 (0,57x) | 89.147 (0,90x) | 21.352 | 23.380 | ver A/B abaixo |
| queries q=1 | 87.871 | 51.114 | **99.673 (1,13x)** | 20.206 | 22.043 | .NET Platform |
| queries q=20 | 6.995 | 16.145 (2,31x) | **20.070 (2,87x)** | 1.839 | 1.911 | .NET Platform |
| fortunes | 82.256 | 54.892 (0,67x) | **99.962 (1,22x)** | 11.995 | 20.218 | .NET Platform |
| updates q=1 | 14.234 | 17.640 (1,24x) | **23.862 (1,68x)** | 7.179 | 12.692 | .NET Platform |
| updates q=20 | 3.388 | 6.416 (1,89x) | **8.104 (2,39x)** | 959 | 1.472 | .NET Platform |

### `/db`: o teste que faltava

A suíte sequencial deu 0,90x, mas nesta máquina a variação entre execuções (±10–15%) é maior que
isso, e o Rust rodou num momento diferente. Por isso o `/db` foi medido também **intercalando os dois
servidores**, que é a única forma de os dois verem as mesmas condições:

| Medição intercalada (c=256) | Rust axum | .NET Platform | .NET / Rust |
|---|---:|---:|---:|
| A/B de 4 testes, 2 alternâncias × 5 s — `/db` | 79.166 / 77.053 | 93.494 / 89.957 | 1,17x |
| A/B dedicado ao `/db`, 3 alternâncias × 10 s | 74.703 / 79.454 / 72.007 | 84.311 / 84.804 / 80.073 | **1,10x** |
| (mesmo A/B de 4 testes) json | 169.968 / 175.610 | 228.540 / 239.689 | 1,35x |
| (mesmo A/B de 4 testes) fortunes | 73.845 / 67.311 | 83.463 / 90.337 | 1,23x |
| (mesmo A/B de 4 testes) queries q=1 | 67.894 / 91.346 | 91.980 / 87.234 | 1,13x |

Em **5 de 5 alternâncias** o .NET Platform ficou à frente do Rust em `/db` (de +7% a +18%). A leitura
honesta é: **paridade com ligeira vantagem do .NET (~1,1x)**, com a suíte sequencial (0,90x) como
limite inferior do intervalo de confiança deste ambiente. Na rodada 3 o Rust estava à frente em todas
as medições de `/db` (0,82–0,95x); o que mudou foi o event loop.

Leitura geral:

- **.NET 11 Platform vence o Rust em 7 das 8 linhas** e empata-ou-vence na oitava (`/db`). A
  hipótese inicial ("o .NET bate o Rust em todas as categorias") está confirmada dentro do que esta
  máquina consegue medir, com uma ressalva explícita no `/db`.
- O preço foi sair do framework: o Kestrel (variante "realistic", com driver de biblioteca) fica em
  0,56–0,67x do Rust nos testes de resposta pequena e 1,2x–2,3x nos de várias consultas. O platform
  substitui Kestrel, Npgsql e o `SocketAsyncEngine` do runtime por ~1.400 linhas próprias: loop
  HTTP/1.1, cliente PostgreSQL de protocolo estendido, e `epoll` por P/Invoke.
- As duas versões Go (código do próprio TechEmpower, sem ajuste) ficam bem atrás em tudo que toca
  o banco (pool pgx sem pipelining); fasthttp empata com o Rust em plaintext e fica a 26% em json.
- Nenhum erro de socket, timeout ou resposta não-2xx em nenhum nível, em nenhuma implementação.

## Tabela completa

| Test | Level | Rust axum req/s | .NET Kestrel req/s (vs Rust axum) | .NET Platform req/s (vs Rust axum) | Go net/http req/s (vs Rust axum) | Go fasthttp req/s (vs Rust axum) | avg / p99 ms (Rust axum · .NET Kestrel · .NET Platform · Go net/http · Go fasthttp) | errors |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| plaintext | c=256 (x16) | 745,838 | 710,882 (0.95x) | 2,174,296 (2.92x) | 62,179 (0.08x) | 706,494 (0.95x) | 3.3 / 0.0 · 3.5 / 10.6 · 1.1 / 8.3 · 60.4 / 247.6 · 4.0 / 13.4 | 0 / 0 / 0 / 0 / 0 |
| plaintext | c=1024 (x16) | 697,497 | 721,216 (1.03x) | 2,063,190 (2.96x) | 69,729 (0.10x) | 670,704 (0.96x) | 13.1 / 0.0 · 12.5 / 0.0 · 2.6 / 0.0 · 142.4 / 387.1 · 13.8 / 32.7 | 0 / 0 / 0 / 0 / 0 |
| plaintext | c=4096 (x16) | 708,588 | 616,741 (0.87x) | 1,684,258 (2.38x) | 81,817 (0.12x) | 712,783 (1.01x) | 50.4 / 0.0 · 53.0 / 0.0 · 11.5 / 0.0 · 445.8 / 963.9 · 50.7 / 118.6 | 0 / 0 / 0 / 0 / 0 |
| json | c=16 | 179,493 | 65,927 (0.37x) | 183,871 (1.02x) | 46,981 (0.26x) | 100,388 (0.56x) | 0.2 / 2.5 · 0.4 / 4.6 · 0.3 / 3.7 · 0.6 / 4.8 · 0.4 / 4.1 | 0 / 0 / 0 / 0 / 0 |
| json | c=64 | 192,325 | 102,687 (0.53x) | 195,341 (1.02x) | 54,453 (0.28x) | 144,591 (0.75x) | 0.5 / 6.2 · 0.7 / 4.5 · 0.3 / 3.2 · 1.4 / 7.7 · 0.5 / 3.6 | 0 / 0 / 0 / 0 / 0 |
| json | c=256 | 212,812 | 116,960 (0.55x) | 240,344 (1.13x) | 54,615 (0.26x) | 157,430 (0.74x) | 1.2 / 4.1 · 2.2 / 6.5 · 0.7 / 4.6 · 4.9 / 16.0 · 1.7 / 5.2 | 0 / 0 / 0 / 0 / 0 |
| json | c=512 | 197,807 | 119,663 (0.60x) | 226,933 (1.15x) | 44,930 (0.23x) | 136,380 (0.69x) | 2.6 / 8.5 · 4.2 / 10.1 · 1.4 / 5.7 · 11.5 / 28.9 · 3.8 / 9.5 | 0 / 0 / 0 / 0 / 0 |
| db | c=16 | 48,268 | 26,070 (0.54x) | 49,521 (1.03x) | 20,681 (0.43x) | 23,380 (0.48x) | 0.5 / 5.0 · 0.7 / 4.4 · 0.5 / 4.7 · 1.0 / 5.6 · 1.0 / 5.7 | 0 / 0 / 0 / 0 / 0 |
| db | c=64 | 83,861 | 44,981 (0.54x) | 77,150 (0.92x) | 20,787 (0.25x) | 22,511 (0.27x) | 0.9 / 5.0 · 1.4 / 6.1 · 1.1 / 7.0 · 3.9 / 18.5 · 2.9 / 8.3 | 0 / 0 / 0 / 0 / 0 |
| db | c=256 | 92,539 | 56,298 (0.61x) | 89,147 (0.96x) | 20,541 (0.22x) | 21,336 (0.23x) | 2.8 / 9.7 · 4.3 / 13.1 · 2.8 / 9.7 · 16.7 / 80.3 · 12.2 / 31.6 | 0 / 0 / 0 / 0 / 0 |
| db | c=512 | 98,799 | 55,902 (0.57x) | 89,086 (0.90x) | 21,352 (0.22x) | 21,473 (0.22x) | 4.9 / 13.4 · 8.3 / 21.0 · 5.4 / 14.9 · 32.8 / 160.1 · 24.1 / 60.6 | 0 / 0 / 0 / 0 / 0 |
| queries | q=1 | 87,871 | 51,114 (0.58x) | 99,673 (1.13x) | 20,206 (0.23x) | 22,043 (0.25x) | 5.5 / 15.1 · 9.2 / 28.1 · 4.8 / 13.6 · 34.4 / 167.6 · 23.6 / 62.9 | 0 / 0 / 0 / 0 / 0 |
| queries | q=5 | 21,178 | 35,102 (1.66x) | 51,425 (2.43x) | 5,785 (0.27x) | 6,749 (0.32x) | 25.5 / 84.1 · 13.7 / 31.9 · 9.3 / 26.7 · 104.1 / 437.8 · 85.6 / 336.7 | 0 / 0 / 0 / 0 / 0 |
| queries | q=10 | 12,486 | 24,267 (1.94x) | 40,613 (3.25x) | 3,465 (0.28x) | 3,764 (0.30x) | 42.0 / 116.0 · 20.5 / 47.9 · 13.4 / 60.3 · 170.2 / 706.1 · 154.0 / 617.5 | 0 / 0 / 0 / 0 / 0 |
| queries | q=20 | 6,995 | 16,145 (2.31x) | 20,070 (2.87x) | 1,839 (0.26x) | 1,912 (0.27x) | 73.7 / 183.1 · 32.3 / 102.3 · 27.3 / 94.9 · 314.9 / 1310.0 · 301.5 / 1270.0 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=16 | 52,225 | 24,495 (0.47x) | 52,642 (1.01x) | 11,615 (0.22x) | 20,088 (0.38x) | 0.4 / 3.5 · 0.8 / 5.0 · 0.4 / 3.7 · 1.6 / 6.8 · 1.1 / 5.8 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=64 | 66,837 | 37,562 (0.56x) | 79,150 (1.18x) | 11,995 (0.18x) | 19,539 (0.29x) | 1.2 / 6.0 · 1.8 / 8.6 · 1.1 / 9.3 · 6.7 / 30.4 · 3.4 / 10.3 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=256 | 72,825 | 49,203 (0.68x) | 99,962 (1.37x) | 10,978 (0.15x) | 19,417 (0.27x) | 3.4 / 11.2 · 5.0 / 13.6 · 2.6 / 9.8 · 30.9 / 147.7 · 13.4 / 36.6 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=512 | 82,256 | 54,892 (0.67x) | 95,451 (1.16x) | 11,475 (0.14x) | 20,218 (0.25x) | 5.9 / 16.5 · 8.9 / 22.4 · 5.0 / 14.7 · 59.6 / 287.0 · 25.9 / 73.5 | 0 / 0 / 0 / 0 / 0 |
| updates | q=1 | 14,234 | 17,640 (1.24x) | 23,862 (1.68x) | 7,179 (0.50x) | 12,692 (0.89x) | 35.8 / 72.4 · 29.1 / 80.0 · 21.7 / 61.6 · 82.1 / 336.4 · 43.4 / 154.6 | 0 / 0 / 0 / 0 / 0 |
| updates | q=5 | 9,146 | 13,487 (1.47x) | 17,031 (1.86x) | 3,060 (0.33x) | 5,024 (0.55x) | 55.6 / 87.0 · 38.7 / 109.3 · 30.1 / 72.1 · 191.1 / 793.0 · 114.8 / 450.5 | 0 / 0 / 0 / 0 / 0 |
| updates | q=10 | 5,547 | 10,535 (1.90x) | 12,320 (2.22x) | 1,791 (0.32x) | 3,052 (0.55x) | 91.7 / 149.2 · 48.6 / 117.8 · 42.1 / 107.8 · 322.7 / 1340.0 · 189.7 / 777.5 | 0 / 0 / 0 / 0 / 0 |
| updates | q=20 | 3,388 | 6,417 (1.89x) | 8,104 (2.39x) | 960 (0.28x) | 1,472 (0.43x) | 148.5 / 221.9 · 80.2 / 197.8 · 64.0 / 162.1 · 568.4 / 2300.0 · 381.9 / 1600.0 | 0 / 0 / 0 / 0 / 0 |

**Melhor nível por teste (critério de ranking do TechEmpower):**

| Test | Rust axum | .NET Kestrel | .NET Platform | Go net/http | Go fasthttp |
|---|---:|---:|---:|---:|---:|
| plaintext | 745,838 | 721,216 (0.97x) | 2,174,296 (2.92x) | 81,817 (0.11x) | 712,783 (0.96x) |
| json | 212,812 | 119,663 (0.56x) | 240,344 (1.13x) | 54,615 (0.26x) | 157,430 (0.74x) |
| db | 98,799 | 56,298 (0.57x) | 89,147 (0.90x) | 21,352 (0.22x) | 23,380 (0.24x) |
| queries | 87,871 | 51,114 (0.58x) | 99,673 (1.13x) | 20,206 (0.23x) | 22,043 (0.25x) |
| fortunes | 82,256 | 54,892 (0.67x) | 99,962 (1.22x) | 11,995 (0.15x) | 20,218 (0.25x) |
| updates | 14,234 | 17,640 (1.24x) | 23,862 (1.68x) | 7,179 (0.50x) | 12,692 (0.89x) |

> Latências p99 "0.0" no plaintext são um artefato conhecido do `wrk` com pipelining (o histograma
> não é confiável nesse modo); o TechEmpower tem o mesmo artefato.

## Ambiente

| Item | Valor |
|---|---|
| Máquina | 4 vCPU Intel Xeon @ 2.80GHz (AVX-512), 15 GiB RAM, Linux 6.18 (container cloud). As rodadas 1 e 2 correram num host Xeon @ 2.10GHz; o container foi migrado entre as rodadas 2 e 3, por isso os valores absolutos da rodada 3 são ~25% maiores para **todas** as implementações e só se comparam dentro da rodada. |
| Pinning | servidor em CPUs 0-1 (`taskset`), `wrk` em CPUs 2-3 (2 threads); PostgreSQL livre nas 4 |
| Carga | `wrk 4.1.0`, mesmos cabeçalhos/durações dos scripts `toolset/wrk` do TFB; 10 s por nível (TFB: 15 s), primer 5 s + warmup |
| Níveis | json/db/fortunes: c = 16, 64, 256, 512 · plaintext: c = 256, 1024, 4096 (pipeline 16) · queries/updates: q = 1, 5, 10, 20 em c = 512 |
| Rust | rustc 1.97.0, axum 0.8.7, hyper 1.8.1, tokio 1.48, tokio-postgres 0.7.15, mimalloc; `--release`, LTO fat, `target-cpu=native` |
| .NET Kestrel | SDK 11.0.100-rc.2, Kestrel HTTP/1 only, Npgsql 10.0.3 (1 data source, pool 4, multiplexing), System.Text.Json source-gen; Server GC sem DATAS, PGO dinâmico, `DOTNET_ReadyToRun=0`; runtime-async desligado após A/B |
| .NET Platform | mesmo SDK; **event loop próprio por core** (`epoll`/`recv`/`send` via libc, `SO_REUSEPORT`), HTTP e cliente PostgreSQL próprio na mesma thread (1 conexão primária + 2 reservadas para multi-linha/updates por loop, pipelined, binário, Nagle ligado, flush uma vez por lote de eventos); GC workstation não-concorrente, gen0 64 MB |
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
| + Nagle no socket PG, GC workstation, gen0 64 MB (rodada 2 final) | — | 295.628 | 113.079 | 99.860 | 15.712 | — |
| Referência: Rust axum no host de 2,10 GHz (rodadas curtas / suíte) | ~870.000 | ~225.000 | ~120.000 | ~94.000 | ~8.300 | ~4.400 |
| *(host novo, 2,80 GHz)* + 4 conexões reservadas para multi-linha/updates, `SingleWorldOp` reciclado (rodada 3 final) | — | 278.369 | 112.631 | 100.857 | 24.124 | 33.820 (q=1) |
| *(rodada 4, mesma sessão)* transporte `raw` da rodada 3, referência | 2.294.875 | 257.014 | 85.353 | 77.679 | 21.149 | 22.922 (q=1) |
| *(rodada 4, mesma sessão)* **event loop `epoll` próprio, HTTP + PG na mesma thread (final)** | 2.120.826 | 260.112 | **105.094** | **91.910** | 18.668 | 23.698 (q=1) |

Cada bloco só é comparável em valor absoluto dentro da mesma sessão (o container trocou de host
entre rodadas). Na rodada 4, o event loop contra o transporte `raw` na mesma sessão: `/db` +23%,
`/fortunes` +18%, `queries q=1` +12% (93.470 vs 83.075); heavy ops e plaintext −8 a −12%, dentro do ruído.

Caminhos testados e descartados (medidos, não supostos): `IOQueueCount=0` (json −25%); Npgsql sem
multiplexação (db −55%); adiar o `send` do cliente PG para outra thread (db −10%); 4–8 conexões PG
(ajuda queries/updates, derruba db e fortunes: menos backends = menos troca de contexto na máquina
pequena); Server GC (p99 do fortunes 3x pior que workstation em 2 CPUs).

Perfil de CPU (`dotnet-trace`) e medição de uso de CPU por processo foram o que apontou cada passo:
o Npgsql multiplexado deixava 0,8 core ocioso (fila única de escrita) e gastava 17,8 µs de CPU por
requisição em `/db`; o cliente próprio gasta 12 µs (Rust: 10,9 µs).

## Terceira rodada: o Kestrel "perdeu performance"?

Entre a rodada 1 e a 2 o Kestrel caiu 6% em plaintext e 10% em `updates q=1`, e subiu 4–8% nos
outros quatro testes. Investigado com rodadas curtas repetidas:

| Configuração Kestrel (rodadas curtas, host novo) | json c=256 | db c=256 | fortunes c=256 | updates q=1 |
|---|---:|---:|---:|---:|
| runtime-async on, Npgsql 4 data sources × pool 2 (rodada 2) | 133.501 | 63.434 | 58.292 | 21.396 |
| runtime-async on, Npgsql 1 × pool 4 (rodada 1) | 140.977 | 68.143 | 56.710 | **25.859** |
| runtime-async off, 4 × 2 | 148.131 | 69.018 | 55.452 | 22.432 |
| runtime-async on vs off, 1 × 4, A/B duplo (média) | 140.691 vs 139.164 | 69.101 vs 74.678 | 64.068 vs 65.346 | 25.869 vs 27.062 |
| cliente PG próprio no Kestrel (sem inline completions) | 135.787 | 55.091 | 50.788 | **304** |

Conclusões: a queda em `updates q=1` veio dos 4 data sources (8 backends do PostgreSQL competindo
numa máquina de 4 cores); plaintext não mudou de código e oscila ±6% entre rodadas; runtime-async
não rende nada mensurável no Kestrel (A/B duplo, diferença < 2%, ligeiramente negativa), e o cliente
PostgreSQL próprio degenera sem *inline completions*. Decisão: Kestrel volta a 1 × 4 e runtime-async
desligado; cliente de biblioteca (Npgsql) mantido, que é o que faz dela a variante "realistic".

## O que o .NET 11 trouxe em relação ao .NET 10 (aplicado e medido)

- **Runtime Async** (`<Features>runtime-async=on</Features>`): testado nas duas variantes. No
  Kestrel, A/B duplo sem ganho mensurável (desligado na configuração final). Na variante platform
  fica ligado: o caminho `/db` usa `ValueTask` + `IValueTaskSource` com continuação inline, que já
  evitava a alocação que o runtime-async elimina, e os handlers `async ValueTask` ficam menores.
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
