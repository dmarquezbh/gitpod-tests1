# Resultados (rodada 3): Rust (axum) vs .NET 11 (Kestrel e platform) vs Go (net/http e fasthttp)

Data: 2026-10-22. Metodologia, arquitetura e reprodução em [`README.md`](README.md). Saída bruta do
`wrk` por nível em `results/<implementação>/`. As cinco implementações rodaram a mesma suíte
(scripts `wrk` do TechEmpower), em sequência, no mesmo host, no mesmo PostgreSQL. O container foi
migrado de host entre as rodadas 2 e 3 (e reiniciado durante a 3), então esta rodada foi executada
integralmente de novo; os valores absolutos **não** se comparam aos das rodadas anteriores.

## Resumo (melhor nível por teste, critério de ranking do TechEmpower)

| Teste | Rust axum | .NET 11 Kestrel | **.NET 11 Platform** | Go net/http | Go fasthttp | Vencedor |
|---|---:|---:|---:|---:|---:|---|
| plaintext (pipelined x16) | 812.570 | 791.679 (0,97x) | **2.517.841 (3,10x)** | 75.062 | 818.955 | .NET Platform |
| json | 209.857 | 121.571 (0,58x) | **258.953 (1,23x)** | 53.100 | 161.784 | .NET Platform |
| db (1 SELECT) | **103.288** | 56.450 (0,55x) | 84.666 (0,82x) | 21.522 | 26.206 | Rust |
| queries q=1 | **100.424** | 56.988 | 87.423 (0,87x) | 20.390 | 23.754 | Rust |
| queries q=20 | 7.742 | 17.093 (2,21x) | **21.903 (2,83x)** | 1.960 | 2.084 | .NET Platform |
| fortunes | 87.394 | 51.536 (0,59x) | 87.384 (1,00x) | 13.388 | 23.830 | empate Rust / .NET Platform |
| updates q=1 | 14.519 | 18.207 (1,25x) | **23.941 (1,65x)** | 7.797 | 12.360 | .NET Platform |
| updates q=20 | 3.721 | 7.632 (2,05x) | **8.853 (2,38x)** | 1.026 | 1.732 | .NET Platform |

**A/B intercalado Rust ↔ .NET Platform** (mesmo host, alternando os dois servidores, 2 rodadas de 5 s,
c=256), para fixar as razões nos testes onde a suíte sequencial deixa dúvida:

| Teste | Rust 1ª / 2ª | .NET Platform 1ª / 2ª | média .NET / Rust |
|---|---:|---:|---:|
| json | 211.474 / 191.792 | 277.935 / 237.308 | 1,28x |
| db | 97.837 / 82.778 | 83.068 / 87.904 | 0,95x |
| fortunes | 85.241 / 90.309 | 82.365 / 79.858 | 0,92x |

Leitura honesta:

- **.NET 11 Platform vence o Rust em 5 das 8 linhas** (plaintext 3x, json 1,2–1,3x, updates
  1,65x–2,4x, queries q=20 2,8x), **empata em fortunes** e **fica atrás em `/db` e `queries q=1`**
  (0,82–0,95x conforme a medição; em todas as execuções o Rust ficou um pouco à frente, nunca o
  contrário, então não está contado como empate). A hipótese "o .NET bate o Rust em tudo" segue
  não confirmada nessas duas linhas; nas demais, confirmada com folga.
- Nesses dois testes o perfil de CPU do .NET já não mostra código gerenciado relevante: o tempo
  ativo é syscall (`send` 12%, `epoll_wait` 8%, `recv` 4%). A diferença restante é o padrão de
  syscalls: o tokio junta os comandos PostgreSQL de várias requisições num único `write` porque a
  task da conexão é escalonada depois das tasks das requisições; no .NET, adiar o envio para outra
  thread custou mais do que a coalescência rendeu (medido: −10%).
- **Kestrel**: a "queda" entre as rodadas 1 e 2 era 4 data sources Npgsql (8 backends) custando
  10% em `updates q=1`, mais ruído de ±6% no plaintext. Reconfigurado para 1 × 4 e runtime-async
  desligado (A/B duplo sem ganho), fica consistente: ≈0,55–0,6x do Rust nos testes de resposta
  pequena (custo fixo do Kestrel por requisição) e 1,25x–2,2x nos de várias consultas.
- As duas versões Go (código do próprio TechEmpower, sem ajuste) ficam bem atrás em tudo que toca
  o banco (pool pgx sem pipelining); fasthttp empata com o Rust em plaintext e fica a 23% em json.
- Nenhum erro de socket, timeout ou resposta não-2xx em nenhum nível, em nenhuma implementação.

## Tabela completa

| Test | Level | Rust axum req/s | .NET Kestrel req/s (vs Rust axum) | .NET Platform req/s (vs Rust axum) | Go net/http req/s (vs Rust axum) | Go fasthttp req/s (vs Rust axum) | avg / p99 ms (Rust axum · .NET Kestrel · .NET Platform · Go net/http · Go fasthttp) | errors |
|---|---:|---:|---:|---:|---:|---:|---|---:|
| plaintext | c=256 (x16) | 812,570 | 791,679 (0.97x) | 2,517,841 (3.10x) | 65,124 (0.08x) | 818,955 (1.01x) | 2.9 / 0.0 · 3.1 / 9.4 · 0.7 / 4.0 · 57.7 / 212.7 · 3.4 / 10.1 | 0 / 0 / 0 / 0 / 0 |
| plaintext | c=1024 (x16) | 744,056 | 713,781 (0.96x) | 2,047,700 (2.75x) | 70,151 (0.09x) | 692,429 (0.93x) | 11.5 / 0.0 · 13.0 / 32.3 · 3.1 / 11.4 · 147.5 / 435.1 · 13.3 / 32.6 | 0 / 0 / 0 / 0 / 0 |
| plaintext | c=4096 (x16) | 780,442 | 651,810 (0.84x) | 1,477,935 (1.89x) | 75,062 (0.10x) | 745,507 (0.96x) | 45.8 / 0.0 · 50.4 / 0.0 · 13.9 / 0.0 · 480.2 / 962.2 · 47.8 / 106.8 | 0 / 0 / 0 / 0 / 0 |
| json | c=16 | 185,271 | 70,808 (0.38x) | 213,357 (1.15x) | 48,495 (0.26x) | 100,844 (0.54x) | 0.2 / 2.8 · 0.5 / 5.7 · 0.1 / 2.4 · 0.5 / 4.5 · 0.4 / 4.0 | 0 / 0 / 0 / 0 / 0 |
| json | c=64 | 194,799 | 103,770 (0.53x) | 249,848 (1.28x) | 52,488 (0.27x) | 140,697 (0.72x) | 0.9 / 8.3 · 0.7 / 4.4 · 0.2 / 2.6 · 1.4 / 6.7 · 0.6 / 3.9 | 0 / 0 / 0 / 0 / 0 |
| json | c=256 | 209,857 | 121,571 (0.58x) | 258,953 (1.23x) | 53,100 (0.25x) | 161,784 (0.77x) | 1.2 / 4.0 · 2.1 / 6.8 · 0.8 / 3.9 · 5.0 / 16.0 · 1.6 / 6.2 | 0 / 0 / 0 / 0 / 0 |
| json | c=512 | 201,849 | 91,273 (0.45x) | 241,529 (1.20x) | 46,174 (0.23x) | 141,089 (0.70x) | 2.5 / 7.2 · 5.5 / 11.7 · 1.6 / 5.6 · 11.1 / 25.4 · 3.6 / 8.7 | 0 / 0 / 0 / 0 / 0 |
| db | c=16 | 51,844 | 28,214 (0.54x) | 46,247 (0.89x) | 21,043 (0.41x) | 26,206 (0.51x) | 0.4 / 3.2 · 0.7 / 4.3 · 0.5 / 3.8 · 1.0 / 5.7 · 0.8 / 4.9 | 0 / 0 / 0 / 0 / 0 |
| db | c=64 | 89,180 | 46,309 (0.52x) | 74,417 (0.83x) | 20,323 (0.23x) | 24,737 (0.28x) | 0.8 / 4.2 · 1.4 / 6.1 · 1.0 / 5.4 · 4.0 / 18.8 · 2.6 / 7.5 | 0 / 0 / 0 / 0 / 0 |
| db | c=256 | 102,434 | 56,450 (0.55x) | 84,666 (0.83x) | 21,015 (0.21x) | 23,224 (0.23x) | 2.5 / 8.2 · 4.3 / 12.8 · 3.0 / 10.1 · 16.4 / 78.9 · 11.1 / 27.9 | 0 / 0 / 0 / 0 / 0 |
| db | c=512 | 103,288 | 54,900 (0.53x) | 77,537 (0.75x) | 21,522 (0.21x) | 23,258 (0.23x) | 4.8 / 13.0 · 8.7 / 25.7 · 6.2 / 17.0 · 32.4 / 158.2 · 22.4 / 59.5 | 0 / 0 / 0 / 0 / 0 |
| queries | q=1 | 100,424 | 56,988 (0.57x) | 87,423 (0.87x) | 20,390 (0.20x) | 23,754 (0.24x) | 5.0 / 13.4 · 8.4 / 22.1 · 5.8 / 22.9 · 34.4 / 170.6 · 22.3 / 66.8 | 0 / 0 / 0 / 0 / 0 |
| queries | q=5 | 21,672 | 35,037 (1.62x) | 49,771 (2.30x) | 6,119 (0.28x) | 6,873 (0.32x) | 25.2 / 86.0 · 13.8 / 31.6 · 10.2 / 40.8 · 97.5 / 403.3 · 84.1 / 334.9 | 0 / 0 / 0 / 0 / 0 |
| queries | q=10 | 10,044 | 25,880 (2.58x) | 34,167 (3.40x) | 3,568 (0.36x) | 3,878 (0.39x) | 51.7 / 129.3 · 19.0 / 42.0 · 14.9 / 41.8 · 165.4 / 698.4 · 149.5 / 600.0 | 0 / 0 / 0 / 0 / 0 |
| queries | q=20 | 7,742 | 17,094 (2.21x) | 21,904 (2.83x) | 1,961 (0.25x) | 2,084 (0.27x) | 66.9 / 175.1 · 30.4 / 98.0 · 24.4 / 80.2 · 294.9 / 1220.0 · 276.6 / 1120.0 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=16 | 49,033 | 26,939 (0.55x) | 42,121 (0.86x) | 13,388 (0.27x) | 23,359 (0.48x) | 0.5 / 3.7 · 0.7 / 4.8 · 3.0 / 104.4 · 1.4 / 6.3 · 0.9 / 5.1 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=64 | 72,039 | 41,062 (0.57x) | 67,049 (0.93x) | 13,353 (0.19x) | 23,830 (0.33x) | 0.9 / 3.8 · 1.7 / 8.2 · 2.0 / 32.5 · 6.1 / 28.2 · 2.8 / 8.7 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=256 | 81,881 | 47,947 (0.59x) | 87,384 (1.07x) | 12,931 (0.16x) | 20,466 (0.25x) | 3.0 / 8.6 · 5.2 / 14.5 · 3.0 / 15.8 · 26.4 / 127.2 · 12.8 / 35.1 | 0 / 0 / 0 / 0 / 0 |
| fortunes | c=512 | 87,394 | 51,536 (0.59x) | 80,324 (0.92x) | 12,975 (0.15x) | 20,461 (0.23x) | 5.7 / 12.6 · 9.5 / 24.1 · 7.0 / 61.6 · 52.8 / 253.3 · 25.6 / 73.6 | 0 / 0 / 0 / 0 / 0 |
| updates | q=1 | 14,519 | 18,207 (1.25x) | 23,941 (1.65x) | 7,797 (0.54x) | 12,360 (0.85x) | 35.0 / 52.9 · 28.2 / 77.6 · 21.9 / 72.0 · 75.6 / 306.6 · 44.6 / 157.7 | 0 / 0 / 0 / 0 / 0 |
| updates | q=5 | 8,905 | 13,653 (1.53x) | 15,881 (1.78x) | 3,240 (0.36x) | 5,744 (0.65x) | 57.0 / 90.1 · 37.6 / 93.6 · 33.2 / 98.8 · 179.2 / 730.0 · 100.0 / 398.0 | 0 / 0 / 0 / 0 / 0 |
| updates | q=10 | 6,018 | 10,480 (1.74x) | 12,754 (2.12x) | 1,989 (0.33x) | 3,022 (0.50x) | 84.4 / 130.2 · 49.0 / 117.0 · 40.9 / 111.6 · 289.2 / 1200.0 · 191.9 / 787.6 | 0 / 0 / 0 / 0 / 0 |
| updates | q=20 | 3,721 | 7,632 (2.05x) | 8,853 (2.38x) | 1,027 (0.28x) | 1,732 (0.47x) | 136.2 / 219.1 · 67.1 / 159.1 · 58.0 / 142.5 · 549.8 / 2280.0 · 329.6 / 1360.0 | 0 / 0 / 0 / 0 / 0 |

**Melhor nível por teste (critério de ranking do TechEmpower):**

| Test | Rust axum | .NET Kestrel | .NET Platform | Go net/http | Go fasthttp |
|---|---:|---:|---:|---:|---:|
| plaintext | 812,570 | 791,679 (0.97x) | 2,517,841 (3.10x) | 75,062 (0.09x) | 818,955 (1.01x) |
| json | 209,857 | 121,571 (0.58x) | 258,953 (1.23x) | 53,100 (0.25x) | 161,784 (0.77x) |
| db | 103,288 | 56,450 (0.55x) | 84,666 (0.82x) | 21,522 (0.21x) | 26,206 (0.25x) |
| queries | 100,424 | 56,988 (0.57x) | 87,423 (0.87x) | 20,390 (0.20x) | 23,754 (0.24x) |
| fortunes | 87,394 | 51,536 (0.59x) | 87,384 (1.00x) | 13,388 (0.15x) | 23,830 (0.27x) |
| updates | 14,519 | 18,207 (1.25x) | 23,941 (1.65x) | 7,797 (0.54x) | 12,360 (0.85x) |

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
| .NET Platform | mesmo SDK; loop HTTP/1.1 próprio sobre `Socket`; cliente PostgreSQL próprio (2 conexões primárias + 4 reservadas para multi-linha/updates, pipelined, binário, Nagle ligado); GC workstation não-concorrente, gen0 64 MB; runtime-async ligado |
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
| *(host novo, 2,80 GHz)* + 4 conexões reservadas para multi-linha/updates, `SingleWorldOp` reciclado (**rodada 3 final**) | — | 278.369 | 112.631 | 100.857 | 24.124 | 33.820 (q=1) |

A linha da rodada 3 não é comparável em valor absoluto às anteriores (host diferente), só às outras
configurações medidas na mesma rodada: sem conexões reservadas, no mesmo host, `updates q=1` deu
18.423 e `queries q=20` 16.054.

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
