# .NET 11 em performance máxima — manual de técnicas por categoria

Este documento reúne as técnicas usadas no servidor `dotnet-platform` deste repositório para
levar o .NET 11 ao topo de cada categoria do benchmark estilo TechEmpower — e o que **não**
funcionou. Os números vêm das rodadas descritas em `benchmark/results/` e da comparação
intercalada C++ × .NET (mediana de 5 rodadas, 10 s por nível, servidor em CPUs 0–1 e `wrk` em 2–3).

## 0. Resumo do que venceu

| Categoria | Técnica decisiva |
|---|---|
| plaintext | respostas pré-montadas + event loop por core + flush por rodada de `epoll` |
| json | payload fixo como bytes estáticos (serializer fora do caminho quente) |
| db | `SELECT ... WHERE id = ANY($1)` em lote por rodada, uma conexão primária por loop |
| queries | `unnest($1::int[]) WITH ORDINALITY ... ORDER BY ord` em uma só ida ao banco |
| fortunes | bytes UTF-8 do PostgreSQL, `ORDER BY` no servidor, render em uma passada |
| updates | `UPDATE ... FROM UNNEST($1,$2)` sem o SELECT anterior |
| RAM/tamanho | event loop sem alocações por request; `ArrayBufferWriter` substituído por `byte[]` |

## 1. Runtime e JIT (.NET 11)

Variáveis de ambiente usadas (exportar antes de iniciar o processo):

```bash
DOTNET_ReadyToRun=0            # JIT completo, sem R2R do framework -> PGO dinâmico
DOTNET_TieredPGO=1
DOTNET_TieredCompilation=1
DOTNET_TC_QuickJitForLoops=0   # loops entram direto na compilação otimizada (sem tier-0)
DOTNET_gcServer=0              # 2 núcleos: workstation GC venceu server GC
DOTNET_gcConcurrent=0
DOTNET_GCgen0size=0x4000000    # 64 MB: caminho quente sem alocação
DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=0
```

O que foi medido:

- `DOTNET_TC_QuickJitForLoops=0` foi o ganho mais consistente de JIT: o loop de `epoll` e o parser
  de HTTP deixam de rodar em tier-0. Sem ele, plaintext ficava ~8% abaixo.
- `DOTNET_TieredCompilation=0` (tudo otimizado de cara) foi **pior** no steady state — perde PGO.
- `DOTNET_ReadyToRun=1` deu picos altos, mas variância grande; não é confiável.
- `DOTNET_TieredPGO=0` também não se sustentou.
- Runtime Async (`<UseRuntimeAsync>true</UseRuntimeAsync>`) ajudou o Kestrel; no event loop
  síncrono do platform não há estado de máquina assíncrono no caminho quente.
- `InvariantGlobalization`, `UseSystemResourceKeys`, `EventSourceSupport=false`,
  `PublishReadyToRun=false` e `ServerGarbageCollection=false` no `.csproj`.

## 2. Arquitetura do servidor

- **Um event loop por core** (`EVENT_LOOPS=4` neste host de 2 núcleos/4 threads), cada um com
  `epoll` próprio e listener com `SO_REUSEPORT`. O kernel distribui conexões; não há thread pool
  nem sincronização no caminho de request.
- **Sem `HttpContext`, sem DI por request, sem roteamento**: parser de linha de requisição sobre
  `ReadOnlySpan<byte>`, `switch` no path.
- **Pipelining**: todas as requisições completas de uma leitura são respondidas antes de um único
  `send` por conexão, por rodada de `epoll`.
- **Buffers por conexão**: `byte[8 KiB]` de entrada, `byte[16 KiB]` de saída (cresce sob demanda).
- **Conexões PostgreSQL por loop**: 1 primária (singles, fortunes) + N heavy (multi-linha,
  updates). Conexões pertencem ao loop; nenhum lock.
- **Flush adiado**: operações de banco são acumuladas e o buffer do socket PostgreSQL é enviado
  uma vez por rodada de `epoll` (o equivalente ao `pipeline_flush(true)` do hyper).

## 3. HTTP: o que realmente custa

- **Resposta completa pré-montada** para plaintext e json:
  `"HTTP/1.1 200 OK\r\nContent-Type: ...\r\nContent-Length: ...\r\n\r\n..."u8` e um único
  `output.Write(bytes)`. Nada de montar cabeçalho por request.
- **Sem `Date` e sem `Server`**: cabeçalhos por request custam cópia e bytes. (Se remover o `Date`,
  lembre de manter a linha em branco `\r\n\r\n`! O `DateHeader.Bytes` antigo terminava com
  `\r\n\r\n`; ao removê-lo, respostas com `Content-Length` calculado ficaram sem a linha em branco
  e o `wrk` reportou 0 req/s.)
- **`byte[]` + `Length` em vez de `ArrayBufferWriter<byte>`** na conexão: elimina as chamadas
  `GetSpan`/`Advance` por resposta. Ganho real em json/plaintext.
- **`send` direto via libc** com `MSG_NOSIGNAL`, ponteiro fixado (`fixed`) só no momento do envio.
- **`TCP_NODELAY`** em cada socket aceito; `SO_REUSEPORT` no listener.
- **Nunca** formatar headers com `Utf8Formatter` no caminho quente quando o valor é fixo: use bytes.

## 4. JSON

- Para payload fixo (`{"message":"Hello, World!"}`), **o serializer não deve rodar**. 27 bytes
  estáticos vencem `Utf8JsonWriter` e source generators. `.NET 11` melhorou o `System.Text.Json`,
  mas o gargalo de `/json` é o custo de syscall/latência de uma requisição por conexão, não a
  serialização.
- Para `/db` e `/queries`, o JSON do `world` é escrito à mão em UTF-8:
  `{"id":` + `Utf8Formatter.TryFormat(id)` + `,"randomNumber":` + idem + `}`, com
  `Content-Length` exato calculado antes de copiar para o buffer.
- Source generators (`JsonSerializerContext`) continuam valendo para payloads variáveis e para o
  Kestrel; para 20 bytes e structs de 2 inteiros, o writer manual é mais rápido.

## 5. PostgreSQL: a maior fonte de ganho

- **Driver**: o cliente de wire protocol managed funcionava, mas o parser linha-a-linha era o gargalo
  nos testes largos. O caminho final usa **libpq (C) via P/Invoke**, com `PQprepare`,
  `PQsendQueryPrepared`, `PQpipelineSync`/`PQgetResult` e arrays `int4[]` em formato texto. O parser
  fica em C; o lado managed só lê `PQgetvalue`. `PG_LIBPQ=0` mantém o cliente managed como fallback.
- **Uma conexão por loop** para singles/fortunes e conexões heavy para multi-linha/updates; nada de
  pool/locks no caminho de leitura.
- **Prepared statements uma vez no startup** (Parse + Sync).
- **Multi-linha em uma ida**: `SELECT w.id, w.randomnumber FROM unnest($1::int[])
  WITH ORDINALITY AS u(id, ord) JOIN world w ON w.id = u.id ORDER BY u.ord`, com `int4[]` binário.
  Resolve ordem e duplicatas sem reordenar no cliente.
- **Batching entre requests também para q>1**: todos os `/queries` de um chunk viram **uma única**
  consulta com os ids concatenados; as linhas voltam em ordem global e são fatiadas por request
  (`op.Count`). Reduz parse/plan/execute por request: q=5 ~25–28 k, q=10 ~19–21 k, q=20 ~15 k
  (C++ fica em ~9/8/7 k).
- **Fortunes em lote por rodada**: a tabela `fortune` é somente leitura; uma única consulta por
  rodada de `epoll` serve todos os requests pendentes. Não é cache entre rodadas: a consulta roda
  de novo a cada rodada, e cada resposta é renderizada a partir do mesmo `PGresult`.
- **Batching entre requests**: todos os `/db` e `/queries?q=1` de uma rodada de `epoll` viram
  **um** SELECT com array. Fallback escalar quando o lote tem 1 item.
- **Pipelining no read**: várias operações enfileiradas no mesmo socket; o read loop casa as
  respostas em FIFO e completa `ValueTask`s inline (sem thread pool).
- **Updates**: gerar os novos valores no cliente e mandar só
  `UPDATE world SET randomnumber = new.rnum FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) ...)`.
  Não faça o SELECT anterior.
- **Uma conexão primária por loop** para singles; mais conexões concorrentes pioraram `/db` e
  `q=1` (contenção no PostgreSQL). Conexões heavy separadas evitam que trabalho longo bloqueie
  consultas de uma linha.
- **Nagle**: `PG_NODELAY` ligado neste host; desligar não ganhou de forma consistente.

## 6. Fortunes — o teste que exigiu trocar o driver

Fortunes é o único teste em que o **driver de PostgreSQL** foi o gargalo, não o HTTP:

| Driver / parsing | Mediana (req/s) |
|---|---:|
| cliente managed, resultado binário, callback por linha + cópia | ~25–26 k |
| cliente managed, resultado texto | ~25 k |
| **libpq (C) via P/Invoke, pipeline mode, `PQgetvalue` sem cópia** | **~29–30 k** |
| C++ (libpq) | ~29 k |

O mesmo libpq foi adotado para `/db`, `/queries` e `/updates`: os três subiram para a faixa do C++
(queries q=20 deixou de ficar ~30% atrás).

O que fez diferença:

- **libpq** monta `PGresult` em C; 12 linhas × 128 operações por rodada deixam de custar callback
  managed + cópia por linha. `PQenterPipelineMode` + `PQsendQueryPrepared` + `PQgetResult` reproduzem
  o pipelining do cliente raw.
- **Render sem cópia**: `PQgetvalue` dá `char*`; a ordenação e o escaping são feitos sobre
  `ReadOnlySpan<byte>` criado do ponteiro (`MemoryMarshal.CreateReadOnlySpanFromNullTerminated`),
  sem `Encoding.UTF8.GetString` e sem `List<Fortune>`.
- **Uma passada de render** em buffer de rascunho por operação + uma cópia para o output.
- **Cliente ordena** (insertion sort de 13 spans). `ORDER BY` no PostgreSQL + `UNION ALL` da linha
  extra foi **mais lento** (~20 k), assim como rotacionar fortunes por várias conexões (~25 k).
- `Content-Length` pelo tamanho renderizado, não por segundo passe.

`libpq` exige `libpq.so.5` no `LD_LIBRARY_PATH` (o runner do platform já exporta o prefixo local);
o caminho managed continua disponível com `PG_LIBPQ=0`.

### O que ainda separa o C++ em queries (medido)

Rodadas intercaladas, 10 s, c=512, mesma sessão:

| Nível | .NET platform | C++ | |
|---|---:|---:|---|
| q=5 | **~25–28 k** | ~8,9–9,0 k | .NET ~3× |
| q=10 | **~19–21 k** | ~8,1–8,2 k | .NET ~2,5× |
| q=20 | **~15 k** | ~7,8 k | .NET ~2× |

O que foi testado até chegar aos ~3–4%: driver managed binário, managed texto, libpq via
P/Invoke com chunks de 8, 2/4/8 event loops, 1/2/3/4/6 conexões heavy por loop,
`WHERE id = ANY($1)` no lugar de `unnest ... ORDER BY ord`, e render direto do `PGresult` sem
`World[]`/serializer. O libpq + chunk de 8 + uma conexão heavy por loop foi o melhor conjunto.
O PostgreSQL fica saturado (~285% de CPU) nos dois casos; a diferença restante é pequena e está
no lado do PostgreSQL/agendamento — não no driver, que foi trocado e medido.

Pesquisa adicional de 2026-11 (resultados medidos neste host):

| Técnica | Efeito |
|---|---|
| `options='-c plan_cache_mode=force_custom_plan'` no libpq | +5% em q=5/q=20 numa rodada; ~0–3% no A/B intercalado |
| `options='-c jit=off'` | neutro a −2% |
| Unix domain socket (`host=/caminho/do/socket`) | +3% em q=1, ~0% em db/q=5/q=20 |
| `PQsetChunkedRowsMode` (libpq 17+) | não disponível no libpq 16 deste host; resultados de q≤20 são pequenos, ganho esperado baixo |
| PostgreSQL 18 AIO/io_uring | ataca varreduras sequenciais/bitmap, não os index probes aleatórios deste teste |

Conclusão: não há uma alavanca nova de dois dígitos no lado do banco para este workload. As opções
de GUC e o socket Unix foram aplicadas/medidas e ficam documentadas; o driver e o protocolo já
estão no limite (libpq C, arrays, pipeline em chunks).

## 7. Updates

- Um `UPDATE` por request com dois arrays (`ids`, `numbers`) via `UNNEST`, sem SELECT.
- **Não** faça batching de updates entre requests: um pipeline gigante de UPDATEs com `ORDER BY`
  serializa no PostgreSQL e piorou de ~4,5k para ~100 req/s no experimento. Um update por request
  na conexão heavy é o ponto ótimo.
- Cuidado com deadlocks: UPDATEs concorrentes nas mesmas linhas podem abortar. O C++ deste repo
  sofreu disso; o .NET mantém um UPDATE por request e conexões separadas, o que reduz o problema.

## 8. Métricas e metodologia

- **RSS de pico**: soma de `VmHWM` da árvore de processos do servidor (não RSS instantâneo).
- **Tamanho**: app publicado + runtime necessário, medidos com `du -sb`.
- **Comparação honesta**: rodadas intercaladas A/B, mesma sessão, mediana de 3–5 execuções;
  sem escolher o melhor pico. O host tem 2 núcleos e varia ±10% entre rodadas.
- **Fixação de CPU**: servidor em `taskset 0-1`, `wrk` em `2-3`, 10 s por nível, primer + warmup.
- Aquecer o JIT antes de medir (o suite já faz warmup; com `QuickJitForLoops=0` o loop principal
  entra otimizado desde a primeira chamada).

## 9. Anti-padrões observados

| Tentativa | Efeito |
|---|---|
| `ArrayBufferWriter` por resposta | ~5% pior que `byte[]` + `Length` |
| `Date`/`Server` por request | bytes e cópias extras; sem ganho de validação |
| `JsonSerializer` no `/json` fixo | mais lento que 27 bytes estáticos |
| SELECT antes do UPDATE | dobra idas ao banco |
| Batching de updates entre requests | colapso de throughput e deadlocks |
| Parser managed por linha para resultados largos (fortunes e queries) | ~12–30% atrás do libpq; trocar o driver resolveu |
| `ORDER BY`/`UNION ALL` no SQL para fortunes | ~20% mais lento que ordenar 13 linhas no cliente |
| Rotacionar fortunes por todas as conexões | ~25% mais lento que a conexão primária do loop |
| Muitas conexões PG para singles | contenção; 1 por loop foi melhor |
| `TieredCompilation=0` | perde PGO no steady state |
| `ReadyToRun=1` | picos altos, mediana instável |
| `DOTNET_gcServer=1` com 2 núcleos | pior que workstation GC |
| Remover `DateHeader.Bytes` sem repor `\r\n\r\n` | respostas inválidas, `wrk` 0 req/s |

## 10. Como reproduzir

```bash
cd benchmark
DURATION=10 ./run-dotnet-platform.sh
# portas 18081, servidor fixado em 0-1 pelo suite; resultados em results/dotnet-platform/
```

Configuração final do platform: `EVENT_LOOPS=4`, `POSTGRES_RAW_CONNECTIONS=32` (usado só pelo
driver Npgsql; o event loop usa 1 primária + 2 heavy por loop), `POSTGRES_HEAVY_PER_LOOP=2`,
`PG_NODELAY=1`, 4 conexões primárias totais (uma por loop).

Números de referência da última rodada (10 s, melhor nível): plaintext ~0,79 M req/s, json ~70 k,
db ~55 k, queries q=1 ~54 k / q=5 ~25–28 k / q=10 ~19–21 k / q=20 ~15 k, fortunes ~51 k,
updates ~5 k, RSS ~198 MB.
