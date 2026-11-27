# elixir-fast — servidor HTTP/1.1 + PostgreSQL em Elixir puro

> **ENCERRADO em 2026-11-27.** Frente Elixir encerrada por decisão do dev: não competir com Zig. Medições finais
> abaixo; nenhum trabalho pendente. Os cinco pontos que fecharam a conta estão em "Tuning da BEAM e do socket".
> Números finais: db 20.5k, queries q=20 9.2k, fortunes 16.2k, updates q=20 3.6k, json 17.6k, plaintext 117k–255k
> (pipelining depth 16) contra Zig 57.6k / 18.4k / 67k / 5.8k / 71.5k / 653k — 1.6× a 5.6× atrás.

Experimento da rodada Elixir: `gen_tcp` cru (sem Plug/Phoenix/Cowboy), leitura de requests por processo de
conexão e **batching de banco**: cada worker agrupa os pedidos de um lote e resolve todos com uma consulta
`= ANY($1::int[])` (ou um `UPDATE ... FROM UNNEST(...)`).

## Rodar

```bash
export PATH="$HOME/.local/elixir-1.18/bin:$PATH"
DURATION=10 tools/run-suite.sh --name elixir-fast --port 8098 --tests "plaintext json db queries fortunes updates" \
  --out results/elixir-fast-final -- elixir-fast/run.sh
```

Variáveis: `PORT` (8098), `WORKERS` (nº de schedulers), `BATCH_US` (janela de agrupamento, 2000).

## Resultado medido (2 núcleos para o servidor, PostgreSQL local)

| Teste | nível | Elixir fast | Zig (`results/zig`) | Razão |
|---|---|---:|---:|---:|
| plaintext | 1024 | 117.399 | 652.553 | 5,6× |
| json | 512 | 17.614 | 71.477 | 4,1× |
| db | 512 | 20.513 | 57.632 | 2,8× |
| queries q=1 | 512 | 18.760 | 55.984 | 3,0× |
| queries q=20 | 512 | 9.243 | 18.438 | 2,0× |
| fortunes | 512 | 16.180 | 67.020 | 4,1× |
| updates q=1 | 512 | 6.336 | 45.292 | 7,1× |
| updates q=20 | 512 | 3.629 | 5.831 | 1,6× |

Medições oscilam forte nesta máquina (plaintext já mediu 266k no mesmo binário, mesmo pinning); compare
sempre na mesma sessão.

## O que foi corrigido no caminho

1. **Janela de batching por prazo** (`System.monotonic_time`), não `receive ... after` por mensagem: o laço
   antigo reiniciava o relógio a cada chegada e o lote só fechava quando o fluxo parava (~200 ms/pedido).
2. **`socket_options: [{:nodelay, true}]`** no Postgrex.
3. **Ordem canônica por id no UPDATE + retry em `40P01`**: lotes concorrentes geravam deadlock e 500.

## Por que não alcança o Zig

- plaintext/json são limitados por **custo por requisição na BEAM** (um processo + cópia de binário + syscalls);
  o Zig roda um laço epoll com buffers reutilizados. Não há tuning que feche 4–6×.
- nas rotas de banco o piso é o próprio PostgreSQL: `UPDATE` de 512 ids custa ~10 ms lá dentro; o Zig apenas
  mantém 512 consultas em voo com overhead de usuário quase zero. Na BEAM, 512 processos de conexão em 2 núcleos
  custam agendamento suficiente para reduzir o lote efetivo.
- o cliente PostgreSQL próprio (`lib/pg.ex`, protocolo v3 + SCRAM-SHA-256, sem Postgrex/DBConnection) foi
  implementado e medido: **db 20.426 rps contra 20.513 do Postgrex** — o driver não era o gargalo. Com o
  cliente cru o lote de 512 ids volta em ~7 ms e o resto do ciclo (~18 ms) é a BEAM agendando 512 processos
  de conexão em 2 núcleos; é aí que o Zig ganha (laço epoll único, ~4 µs por requisição contra ~35 µs).

## Arquivos

- `lib/fast.ex` — servidor, rotas, renderizadores e workers de banco.
- `run.sh` — entrada usada pelo harness (`tools/run-suite.sh`).

## Tuning da BEAM e do socket — medido

Matriz de flags (mesma sessão, servidor em 2 núcleos, `wrk` nos outros 2), 5 s por medição:

| Configuração | db c=512 | json c=512 |
|---|---:|---:|
| sem flags | 19.884 | 32.265 |
| `+sbwt none +sbwtdcpu none +sbwtdio none` | 20.338 | 32.599 |
| anterior `+S 2:2 +SDcpu 1 +SDio 1 +A 1` | 19.740 | 34.315 |
| anterior `+ +MBas aoffcbf +MBlmbcs 5120 +MMmcs 30` | 16.532 | 34.522 |

Socket: `recbuf/sndbuf 256k` não mudou nada (db 17.961, json 30.596, plaintext 254.734 contra base db 19.198,
json 30.603, plaintext 255.541). `{reuseport, true}` no `gen_tcp.listen` dá `badarg` neste OTP — não existe essa
opção no `inet_tcp`; só no módulo `socket`.

Leitura: **flags de BEAM movem ±5% e alocadores pioram**; o custo é por requisição (recv/send + escalonar 512
processos de conexão em 2 núcleos), não por configuração de VM. `+mode embedded` não roda com `mix run`.
