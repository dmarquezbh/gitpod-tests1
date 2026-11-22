# Graph Report - gitpod-tests1  (2026-11-22)

## Corpus Check
- 165 files · ~107,125 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 496 nodes · 940 edges · 36 communities (22 shown, 14 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 8 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `f4cafc29`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]

## God Nodes (most connected - your core abstractions)
1. `Program` - 63 edges
2. `PgConnection` - 39 edges
3. `DllImport` - 32 edges
4. `PendingOp` - 24 edges
5. `EventLoop` - 20 edges
6. `HttpConn` - 18 edges
7. `PgLoopConnection` - 16 edges
8. `LoopOp` - 15 edges
9. `Bench` - 14 edges
10. `PgProtocol` - 13 edges

## Surprising Connections (you probably didn't know these)
- `LoopOp` --inherits--> `PendingOp`  [EXTRACTED]
  benchmark/dotnet-platform/EventLoop/EventLoopServer.cs → benchmark/dotnet-platform/Pg/PendingOps.cs
- `SingleBatchOp` --inherits--> `PendingOp`  [EXTRACTED]
  benchmark/dotnet-platform/EventLoop/EventLoopServer.cs → benchmark/dotnet-platform/Pg/PendingOps.cs
- `RawDb` --implements--> `IDb`  [EXTRACTED]
  benchmark/dotnet-platform/Pg/RawDb.cs → benchmark/dotnet/Db.cs

## Import Cycles
- 1-file cycle: `benchmark/rust-may-minihttp/src/main.rs -> benchmark/rust-may-minihttp/src/main.rs`

## Communities (36 total, 14 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.09
Nodes (10): int, Conn, DllImport, EpollEvent, safe, SockAddrIn, uint, UnmanagedCallersOnly (+2 more)

### Community 1 - "Community 1"
Cohesion: 0.07
Nodes (22): ArrayBufferWriter, bool, byte, Exception, int, List, ReadOnlySpan, Socket (+14 more)

### Community 2 - "Community 2"
Cohesion: 0.09
Nodes (22): bool, byte, Exception, Fortune, int, List, ReadOnlySpan, Socket (+14 more)

### Community 3 - "Community 3"
Cohesion: 0.08
Nodes (21): Action, bool, Exception, Fortune, int, List, ReadOnlySpan, Stack (+13 more)

### Community 4 - "Community 4"
Cohesion: 0.10
Nodes (26): Arc, PgConnection, BytesMut, Client, Error, HttpService, HttpServiceFactory, Request (+18 more)

### Community 5 - "Community 5"
Cohesion: 0.12
Nodes (9): byte, int, List, ReadOnlySpan, Span, string, PgAuthenticator, PgProtocol (+1 more)

### Community 6 - "Community 6"
Cohesion: 0.23
Nodes (6): String, Connection, HttpExchange, Bench, Db, Row

### Community 7 - "Community 7"
Cohesion: 0.22
Nodes (10): Fortune, int, List, string, Task, ValueTask, World, Db (+2 more)

### Community 8 - "Community 8"
Cohesion: 0.11
Nodes (18): DB_DRIVER, DOTNET_CLI_TELEMETRY_OPTOUT, DOTNET_gcConcurrent, DOTNET_GCgen0size, DOTNET_gcServer, DOTNET_NOLOGO, DOTNET_ReadyToRun, DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS (+10 more)

### Community 9 - "Community 9"
Cohesion: 0.28
Nodes (15): clamp_q(), conn_thread(), db_acquire(), db_release(), handle(), html_escape(), query_param(), rand_id() (+7 more)

### Community 10 - "Community 10"
Cohesion: 0.21
Nodes (8): Fortune, int, List, PgConnection, Task, ValueTask, World, RawDb

### Community 11 - "Community 11"
Cohesion: 0.23
Nodes (12): _clamp(), _connect(), db(), _escape(), fortunes(), _init_pool(), queries(), _rand_id() (+4 more)

### Community 12 - "Community 12"
Cohesion: 0.18
Nodes (10): DOTNET_CLI_TELEMETRY_OPTOUT, DOTNET_NOLOGO, DOTNET_ReadyToRun, DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS, DOTNET_TieredPGO, PATH, PORT, POSTGRES_DATA_SOURCES (+2 more)

### Community 13 - "Community 13"
Cohesion: 0.22
Nodes (6): escapeHtml(), fortunes(), http, { Pool }, PORT, server

### Community 14 - "Community 14"
Cohesion: 0.42
Nodes (8): best_levels(), fmt(), kb_or_mb(), main(), mb(), metrics(), table_footprint(), table_throughput()

### Community 15 - "Community 15"
Cohesion: 0.32
Nodes (3): run-suite.sh script, record(), wrk_run()

### Community 16 - "Community 16"
Cohesion: 0.29
Nodes (6): dependencies, pg, name, private, type, version

### Community 17 - "Community 17"
Cohesion: 0.50
Nodes (3): InitDB(), newPGX(), Pool

### Community 20 - "Community 20"
Cohesion: 0.50
Nodes (3): GOFLAGS, PATH, run-go.sh script

### Community 21 - "Community 21"
Cohesion: 0.50
Nodes (3): net11.0, Npgsql (10.0.3), Microsoft.NET.Sdk.Web

## Knowledge Gaps
- **105 isolated node(s):** `gitpod-tests1 — benchmark Rust vs .NET 11 vs Go`, `Stack`, `Random`, `ArrayBufferWriter`, `World` (+100 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **14 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `PendingOp` connect `Community 3` to `Community 1`?**
  _High betweenness centrality (0.055) - this node is a cross-community bridge._
- **Why does `PgLoopConnection` connect `Community 1` to `Community 11`?**
  _High betweenness centrality (0.033) - this node is a cross-community bridge._
- **What connects `gitpod-tests1 — benchmark Rust vs .NET 11 vs Go`, `Stack`, `Random` to the rest of the system?**
  _106 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.08531187122736418 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.07049180327868852 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.0889894419306184 - nodes in this community are weakly interconnected._
- **Should `Community 3` be split into smaller, more focused modules?**
  _Cohesion score 0.08305647840531562 - nodes in this community are weakly interconnected._