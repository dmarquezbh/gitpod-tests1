# Rust (axum) vs .NET 11 (Kestrel / platform) vs Go (net/http / fasthttp) — TechEmpower-style benchmark

Reimplementação em **.NET 11** da aplicação web Rust usada no
[TechEmpower FrameworkBenchmarks](https://github.com/TechEmpower/FrameworkBenchmarks)
(`frameworks/Rust/axum`, variantes `axum` e `axum-pg`), executando **a mesma suíte de
benchmark** (os scripts `wrk` do próprio TechEmpower) contra as implementações Rust, .NET
(duas variantes) e Go (duas implementações do próprio TechEmpower), no mesmo PostgreSQL.

Ver [`RESULTS.md`](RESULTS.md) para os números.

## Layout

| Caminho | Conteúdo |
|---|---|
| `rust-axum/` | Cópia literal da implementação Rust (commit em `UPSTREAM.txt`, licença em `LICENSE-TFB`). Não foi alterada. |
| `go-std/`, `go-fasthttp/` | Cópias literais das implementações Go do TechEmpower (net/http + pgx v3; fasthttp + pgx v4). Não alteradas. |
| `dotnet/` | Reimplementação em C# / .NET 11 sobre **Kestrel** (variante "realistic": framework HTTP completo, como o axum sobre hyper). |
| `dotnet-platform/` | Reimplementação em C# / .NET 11 com **servidor HTTP/1.1 próprio** sobre o transporte de sockets do Kestrel e `System.IO.Pipelines` (variante "platform", a mesma abordagem das entradas aspnetcore que lideram o TechEmpower). Compartilha `Db.cs`, `Models.cs` e `FortunesRenderer.cs` com `dotnet/`. |
| `tools/run-suite.sh` | Réplica de `toolset/wrk/{concurrency,pipeline,query}.sh` do TFB, sem Docker, com pinning de CPU. |
| `tools/compare.sh` | Junta os dois `summary.csv` e gera as tabelas Markdown. |
| `tools/create-postgres.sql`, `tools/tfb-postgresql.conf` | Schema e tuning do PostgreSQL do TFB. |
| `run-rust.sh`, `run-dotnet.sh`, `run-dotnet-platform.sh`, `run-go.sh` | Compilam e rodam a suíte completa para cada implementação. |
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

## Como as implementações .NET foram feitas (foco em throughput)

### Variante Kestrel (`dotnet/`)

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
  **Runtime Async** (novo no .NET 11) foi medido em A/B duplo nesta variante; a decisão final
  (ligado ou desligado) está no `.csproj` com o motivo, e os números em `RESULTS.md`.
- Banco: Npgsql multiplexado, 1 data source com pool 4. A terceira rodada mostrou que fragmentar em
  4 data sources (ganho em db/fortunes) custa 10% em `updates q=1` por causa dos 8 backends; a
  configuração 1×4 foi a melhor no conjunto. O cliente PostgreSQL próprio (abaixo) **não** é usado
  aqui: sem *inline completions* as continuações caem no thread pool e o desenho de afinidade por
  thread degenera (medido: `/db` a 44k e `updates` a 300 req/s), então o Kestrel fica com o driver
  de biblioteca, que é também o que o caracteriza como variante "realistic".

### Variante Platform (`dotnet-platform/`)

O custo fixo por requisição do Kestrel (criação do `HttpContext`, coleção de features, dicionários
de cabeçalhos, `Date`/`Server`, agendamento) é o que perde para o hyper nos testes de resposta
pequena. A variante platform remove essa camada:

- `SocketTransportFactory` do Kestrel (`IConnectionListenerFactory`) fornece apenas o socket
  como par `PipeReader`/`PipeWriter`; o loop HTTP é nosso (`HttpApplication.cs`).
- Parser de linha de requisição sobre `ReadOnlySpan<byte>` / `SequenceReader<byte>`: encontra
  `\r\n\r\n`, extrai o *target*, separa path e query. Cabeçalhos de entrada não são materializados.
- **Pipelining**: todas as requisições completas de uma leitura são respondidas antes de um único
  `FlushAsync` (equivalente ao `pipeline_flush(true)` do hyper).
- Cabeçalhos de resposta pré-renderizados como literais `u8`; `Date` atualizado por um timer de 1 s
  (`DateHeader.cs`); resposta inteira copiada numa única chamada a `GetSpan`/`Advance`.
- Handlers síncronos (plaintext, json) retornam `ValueTask` concluída: zero alocação por requisição.
- O restante (Npgsql multiplexado, batches, JSON por source generator, renderizador de fortunes) é
  exatamente o mesmo código da variante Kestrel.

Transporte (`HTTP_TRANSPORT`): `kestrel-sockets` usa o `SocketTransportFactory` do Kestrel
(socket → `Pipe` → aplicação); `raw` (`RawSocketServer.cs`, o padrão nos resultados) faz o loop
direto sobre `Socket`: `ReceiveAsync` num `byte[]` por conexão, parse, respostas num buffer de
saída, um `SendAsync` por leitura. Sem Pipe, sem cópia intermediária, a mesma forma de uma
*connection task* do hyper. Foi o que levou o `/json` de ~210k para ~260–310k req/s.

Limitações assumidas (iguais às das entradas "platform" do TechEmpower): só HTTP/1.1, só `GET`
sem corpo, sem `Connection: close` explícito, sem TLS.

### Camada de banco: Npgsql fragmentado ou cliente de protocolo próprio (`dotnet-platform/Pg/`)

O perfil de CPU sob carga de `/db` mostrou duas coisas: o .NET gastava 1,6x mais CPU por consulta
que o tokio-postgres **e** deixava CPU ociosa, porque toda consulta de um `NpgsqlDataSource`
multiplexado passa por um único loop de escrita. Duas respostas, selecionáveis por variável de ambiente:

- `POSTGRES_DATA_SOURCES=N` (ambas as variantes): N `NpgsqlDataSource` independentes, cada thread
  de IO presa a um deles. Com 4 fontes × pool 2: `/db` +14%, `/fortunes` +31%.
- `DB_DRIVER=raw` (só platform): cliente PostgreSQL mínimo e *pipelined* — protocolo estendido,
  statements preparados no startup, parâmetros e resultados binários, autenticação SCRAM-SHA-256,
  uma conexão por thread de IO, escrita com *double buffering* (consultas concorrentes viram um
  único `send`), um loop de leitura que completa `ValueTask`s *inline* (`ManualResetValueTaskSourceCore`).
  É o desenho do tokio-postgres reproduzido em C#; mesmo SQL, mesmo `UPDATE` com `UNNEST`.
  Detalhes que fizeram diferença medida: a conexão é escolhida pela thread onde chegam as leituras
  do seu socket (afinidade igual à do runtime *current-thread*); o `send` é feito inline (adiá-lo
  para outra thread custou mais que a coalescência rendeu); Nagle fica ligado no socket PG, para o
  kernel juntar os `Bind/Execute/Sync` de consultas concorrentes num segmento (+10% em `/db`,
  +20% em `/fortunes`); GC workstation não-concorrente com gen0 de 64 MB (em 2 CPUs, as threads do
  Server GC só competem com as de IO).
  Terceira rodada: **conexões pesadas** (`POSTGRES_RAW_HEAVY_CONNECTIONS=4`): consultas de várias
  linhas e updates vão para 4 conexões reservadas, e o tráfego de linha única fica nas 2 primárias.
  O trabalho longo do PostgreSQL (UPDATE, 20 SELECTs) deixa de enfileirar o `/db`, e o PostgreSQL
  passa a usar mais backends justamente onde é ele o gargalo: `updates q=1` foi de 18,4k para
  33,8k e `queries q=20` de 16k para 24k, sem perder `/db` nem `/fortunes`. E a operação de
  linha única (`SingleWorldOp`) passou a ser reciclada numa pilha por thread: zero alocação por
  requisição em `/db`.

### Go (`go-std/`, `go-fasthttp/`)

Cópias literais das implementações Go do TechEmpower, sem alterações: `go-std` (net/http +
jackc/pgx v3, `./app -db pgx`) e `fasthttp` (valyala/fasthttp + pgx v4 pool). Compiladas com
`GOAMD64=v3 -ldflags="-s -w"`, Go 1.24.7. O fasthttp fixa o host `tfb-database`, resolvido via
`/etc/hosts`. Os parâmetros de query são `?queries=` (e `/update` singular no go-std); o runner
aceita `--queries-url`/`--updates-url` por isso.

## O que o .NET 11 muda em relação ao .NET 10 (e o que foi aplicado)

Fontes: [Performance Improvements in .NET 11](https://devblogs.microsoft.com/dotnet/performance-improvements-in-net-11/)
e [What's new in the .NET 11 runtime](https://learn.microsoft.com/en-us/dotnet/core/whats-new/dotnet-11/runtime).

| Mudança | Opt-in? | Relevância aqui |
|---|---|---|
| **Runtime Async**: `async` gerado pelo JIT em vez de máquinas de estado do compilador; cadeias `Task`→`await` sem `Task` intermediário, continuações reaproveitadas, tiering para métodos async | Sim: `<Features>runtime-async=on</Features>` (aplicado nos dois projetos) | `/db`, `/queries`, `/fortunes`, `/updates` têm 3–4 níveis de `await` por requisição |
| Continuações sem captura/restauração de `ExecutionContext` quando não há `AsyncLocal` em uso | Não | Todo `await` sobre Npgsql e Pipelines |
| `Utf8JsonWriter`: escaping com `SearchValues` pré-computados (benchmark citado: 30,8 µs → 7,9 µs) | Não | Serialização de `/json`, `/db`, `/queries`, `/updates` |
| ThreadPool: menos *fences* e menos *wake-ups* para itens de trabalho pequenos | Não | Continuações de socket e de banco |
| `Random.Next` em laço ~1,8x mais rápido | Não | `random_id` em todos os testes de banco |
| Escape analysis: boxes, enumeradores e `EqualityComparer` alocados em stack; devirtualização de métodos genéricos virtuais | Não | Código do Npgsql e do System.Text.Json |
| Eliminação de *bounds checks* (`i + cns < len`, guarda de span vazio, `IndexOf` + acesso) | Não | Parser HTTP e renderizador de fortunes |
| Baseline x86-64-v2 e alvo R2R x86-64-v3 | Não | Irrelevante aqui (`DOTNET_ReadyToRun=0`, JIT com `target-cpu` nativo) |
| Variáveis `DOTNET_RuntimeAsync` removidas; opt-out só por `<UseRuntimeAsync>false</UseRuntimeAsync>` | — | Documentado para reprodução |

Bibliotecas: Npgsql 10.0.3 é a versão estável mais recente (não há 11.x no NuGet em 2026-10-21);
System.Text.Json e Kestrel vêm do shared framework 11.0 RC2. Não há biblioteca de acesso ao
PostgreSQL mais rápida que o Npgsql com multiplexação no ecossistema; a alternativa seria um cliente
do protocolo de fio escrito à mão, o que foge de "reimplementar a aplicação".

## Revisão da implementação Kestrel (o que foi encontrado)

- Sem bugs funcionais: JSON, clamp de `q`, HTML e `UPDATE` idênticos ao Rust (verificado byte a byte).
- `Content-Length` sempre presente (sem *chunked*), JSON em buffer por thread, sem roteamento, sem DI
  por requisição: o caminho já era o mais curto possível dentro do Kestrel.
- Gargalo real medido: o custo fixo do Kestrel por requisição (≈2x o do hyper nesta máquina), não o
  código da aplicação. Por isso a segunda variante troca a camada HTTP em vez de micro-otimizar.
- `FortunesRenderer` foi extraído para arquivo próprio para ser compartilhado entre as variantes.

## Como reproduzir

```bash
# pré-requisitos: rust toolchain, .NET 11 SDK, wrk, PostgreSQL 16 local
sudo -u postgres psql -c "CREATE USER benchmarkdbuser WITH PASSWORD 'benchmarkdbpass';"
sudo -u postgres psql -c "CREATE DATABASE hello_world OWNER benchmarkdbuser;"
sudo -u postgres psql -d hello_world -f tools/create-postgres.sql
# (opcional) aplicar tools/tfb-postgresql.conf ao postgresql.conf e reiniciar

./run-rust.sh              # -> results/rust/summary.csv
./run-dotnet.sh            # -> results/dotnet/summary.csv
./run-dotnet-platform.sh   # -> results/dotnet-platform/summary.csv
./run-go.sh                # -> results/go-std/summary.csv, results/go-fasthttp/summary.csv
tools/compare.sh "Rust axum=results/rust/summary.csv" ".NET Kestrel=results/dotnet/summary.csv" \
  ".NET Platform=results/dotnet-platform/summary.csv" "Go net/http=results/go-std/summary.csv" "Go fasthttp=results/go-fasthttp/summary.csv"
```
