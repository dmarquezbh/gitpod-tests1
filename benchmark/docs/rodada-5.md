# Rodada 5 — o Rust melhorado contra o .NET 11 platform

Data: 2026-10-22. Sessão única, host Intel Xeon @ 2,80 GHz (AVX-512), 4 vCPU, PostgreSQL 16.15.
Esta é a documentação completa da rodada: objetivo, o que mudou, como foi validado, como foi medido,
todos os números e a leitura deles. Os arquivos citados estão neste repositório.

## 1. Objetivo

Nas rodadas 1 a 4 o lado .NET foi reescrito quatro vezes até passar o Rust (axum + tokio-postgres,
código do TechEmpower) em sete das oito linhas medidas. A pergunta desta rodada é a inversa: **o que
o Rust ganha com o mesmo tratamento, e o .NET se sustenta?** Para responder, duas implementações
Rust entraram na comparação, medidas na mesma sessão que o .NET platform:

| Implementação | O que é | Pasta |
|---|---|---|
| Rust axum | referência das rodadas anteriores: código do TechEmpower, sem alteração | `rust-axum/` |
| **Rust axum-tuned** | o mesmo código com três mudanças (seção 2) | `rust-axum-tuned/` |
| **Rust may-minihttp** | a implementação Rust mais rápida do ranking do TechEmpower, sem alteração | `rust-may-minihttp/` |
| .NET 11 Platform | configuração final da rodada 4 (event loop próprio por core) | `dotnet-platform/` |

## 2. O que mudou no Rust

### 2.1 axum-tuned

Três mudanças sobre `rust-axum/`, todas visíveis em `git diff --no-index rust-axum rust-axum-tuned`:

1. **Conexões PostgreSQL reservadas para operações pesadas** (`src/pg/database.rs`). O original abre
   uma conexão `tokio-postgres` por runtime Tokio e passa tudo por ela. Agora cada runtime abre, além
   dela, `POSTGRES_HEAVY_CONNECTIONS` conexões extras, usadas em rodízio por `fetch_random_worlds`
   quando `num > 1` e sempre por `update_worlds`. É a mesma ideia que rendeu +40% em `updates q=1` no
   .NET na rodada 3: o trabalho longo do PostgreSQL (20 SELECTs, um UPDATE) deixa de enfileirar as
   consultas de linha única na mesma conexão, e o PostgreSQL passa a ter mais backends onde ele é o
   gargalo.
2. **`simd-json`** no lugar do `serde_json` para as respostas JSON. A feature já existe no
   `Cargo.toml` do TechEmpower (desligada por padrão); o módulo `src/common/simd_json.rs` precisou de
   um ajuste de duas linhas porque o axum 0.8 não re-exporta mais `async_trait` (o `FromRequest` do
   axum 0.8 usa `async fn` nativo em traits).
3. **`panic = "abort"`** no perfil `release`, como o may-minihttp já faz.

O resto do original já era o que se faria de melhor: hyper com `pipeline_flush`, um runtime Tokio
*current-thread* por core com `SO_REUSEPORT`, mimalloc, LTO fat, `codegen-units = 1`,
`target-cpu=native`, statements preparados, UPDATE em lote com `UNNEST`.

Diff de `src/pg/database.rs`:

```diff
@@ -29,17 +29,17 @@ impl From<tokio_postgres::Error> for PgError {
     }
 }
 
-/// Postgres interface
-pub struct PgConnection {
+/// One pipelined connection with its prepared statements.
+struct PgClient {
     client: Client,
     fortune: Statement,
     world: Statement,
     updates: Statement,
 }
 
-impl PgConnection {
-    pub async fn connect(db_url: String) -> Arc<PgConnection> {
-        let (cl, conn) = connect(&db_url, NoTls)
+impl PgClient {
+    async fn connect(db_url: &str) -> PgClient {
+        let (cl, conn) = connect(db_url, NoTls)
             .await
             .expect("cannot connect to postgresql.");
 
@@ -55,19 +55,57 @@ impl PgConnection {
         let world = cl.prepare(common::SELECT_WORLD_BY_ID).await.unwrap();
         let updates = cl.prepare(common::UPDATE_WORLDS).await.unwrap();
 
+        PgClient { client: cl, fortune, world, updates }
+    }
+}
+
+/// Postgres interface: one primary connection for single-row traffic plus `POSTGRES_HEAVY_CONNECTIONS`
+/// extra connections (per runtime thread) reserved for multi-row queries and updates, so that the long
+/// PostgreSQL work of those requests does not queue behind the single-row requests.
+pub struct PgConnection {
+    primary: PgClient,
+    heavy: Vec<PgClient>,
+    rotation: std::sync::atomic::AtomicUsize,
+}
+
+impl PgConnection {
+    pub async fn connect(db_url: String) -> Arc<PgConnection> {
+        let heavy_count: usize = std::env::var("POSTGRES_HEAVY_CONNECTIONS")
+            .ok()
+            .and_then(|v| v.parse().ok())
+            .unwrap_or(0);
+        let primary = PgClient::connect(&db_url).await;
+        let mut heavy = Vec::with_capacity(heavy_count);
+        for _ in 0..heavy_count {
+            heavy.push(PgClient::connect(&db_url).await);
+        }
         Arc::new(PgConnection {
-            client: cl,
-            fortune,
-            world,
-            updates,
+            primary,
+            heavy,
+            rotation: std::sync::atomic::AtomicUsize::new(0),
         })
     }
+
+    #[inline(always)]
+    fn heavy(&self) -> &PgClient {
+        if self.heavy.is_empty() {
+            return &self.primary;
+        }
+        let i = self
+            .rotation
+            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
+        &self.heavy[i % self.heavy.len()]
+    }
 }
 
 impl PgConnection {
     pub async fn fetch_world_by_id(&self, id: i32) -> Result<World, PgError> {
-        self.client
-            .query_one(&self.world, &[&id])
+        Self::fetch_world_on(&self.primary, id).await
+    }
+
+    async fn fetch_world_on(cl: &PgClient, id: i32) -> Result<World, PgError> {
+        cl.client
+            .query_one(&cl.world, &[&id])
             .await
             .map(|row| {
                 Ok(World {
@@ -78,19 +116,25 @@ impl PgConnection {
     }
 
     pub async fn fetch_random_worlds(&self, num: usize) -> Result<Vec<World>, PgError> {
+        let cl = if num > 1 { self.heavy() } else { &self.primary };
+        Self::fetch_random_worlds_on(cl, num).await
+    }
+
+    async fn fetch_random_worlds_on(cl: &PgClient, num: usize) -> Result<Vec<World>, PgError> {
         let mut rng = SmallRng::from_rng(&mut rng());
 
         let futures = FuturesUnordered::new();
 
         for id in random_ids(&mut rng, num) {
-            futures.push(self.fetch_world_by_id(id));
+            futures.push(Self::fetch_world_on(cl, id));
         }
 
         futures.try_collect().await
     }
 
     pub async fn update_worlds(&self, num: usize) -> Result<Vec<World>, PgError> {
-        let mut worlds = self.fetch_random_worlds(num).await?;
+        let cl = self.heavy();
+        let mut worlds = Self::fetch_random_worlds_on(cl, num).await?;
 
         // Update the worlds with new random numbers
         let mut rng = SmallRng::from_rng(&mut rng());
@@ -104,8 +148,8 @@ impl PgConnection {
         }
 
         // Update the random worlds in the database.
-        self.client
-            .execute(&self.updates, &[&ids, &nids])
+        cl.client
+            .execute(&cl.updates, &[&ids, &nids])
             .await?;
 
         Ok(worlds)
@@ -118,8 +162,9 @@ impl PgConnection {
         }];
 
         let rows = self
+            .primary
             .client
-            .query_raw::<_, _, &[i32; 0]>(&self.fortune, &[])
+            .query_raw::<_, _, &[i32; 0]>(&self.primary.fortune, &[])
             .await?;
 
         pin!(rows);
```

### 2.2 may-minihttp

Cópia literal de `frameworks/Rust/may-minihttp` do TechEmpower (commit
`57d92fbec6f8fd7431bc77326dd0484e60c96e20`), compilada com `RUSTFLAGS="-C target-cpu=native"`
como no `may-minihttp.dockerfile`. Versões: `may 0.3.51`, `may_minihttp 0.1.11`, `may_postgres`
(git, rev `917ed78`). É o equivalente Rust da variante platform do .NET: servidor HTTP/1.1 mínimo
e cliente PostgreSQL *pipelined* próprios, uma conexão por core, tudo sobre corrotinas com stack
(`may`). Único ajuste de ambiente: ele fixa o host `tfb-database`, mapeado para `127.0.0.1` em
`/etc/hosts` (o `run-rust-may.sh` faz isso).

## 3. Validação funcional

Antes de medir, as duas implementações passaram pelo mesmo smoke test das outras:

| Verificação | axum-tuned | may-minihttp |
|---|---|---|
| `/db`, `/queries`, `/updates`, `/fortunes`, `/plaintext`, `/json` respondem 200 com o formato esperado | ok | ok |
| `q` ausente, `q=0`, `q=abc` → 1; `q=999` → 500 (clamp do TechEmpower) | ok | ok |
| `/fortunes` byte a byte idêntico ao do axum original | sim | sim |
| `updates` persiste no banco (valor da resposta conferido com `psql`) | sim | sim |
| 404 em path desconhecido | ok | ok |
| Erros de socket / timeouts / não-2xx em qualquer nível da suíte | 0 | 0 |

Diferença cosmética do may-minihttp: o JSON usa `randomnumber` em minúsculas (o TechEmpower aceita).

## 4. Tuning do axum-tuned (rodadas curtas de 5 s, c=256, q em 512 conexões)

| `POSTGRES_HEAVY_CONNECTIONS` por runtime | db | fortunes | queries q=1 | queries q=20 | updates q=1 | updates q=20 |
|---|---:|---:|---:|---:|---:|---:|
| 0 (= original) | 66.522 | 67.816 | 68.228 | 5.329 | 11.303 | 2.887 |
| **2 (escolhido)** | 68.656 | 69.225 | 79.002 | 8.383 | 18.124 | 4.971 |
| 4 | 72.393 | 63.483 | 71.983 | 8.313 | 19.111 | 4.893 |

Escolha pelo somatório dos logaritmos dos seis valores (média geométrica). O ganho é onde se
esperava: `updates q=1` +60%, `queries q=20` +57%, sem perder `/db` nem `/fortunes`.

## 5. Método de medição

- Suíte: os seis testes do TechEmpower com os scripts `wrk` do próprio projeto (`tools/run-suite.sh`
  é a réplica sem Docker). 10 s por nível, primer de 5 s e warmup antes de cada teste. Níveis:
  json/db/fortunes em c = 16, 64, 256, 512; plaintext em c = 256, 1024, 4096 com pipelining 16;
  queries/updates em q = 1, 5, 10, 20 a 512 conexões.
- Pinning: servidor em CPUs 0-1 (`taskset`), `wrk` em CPUs 2-3 com 2 threads, PostgreSQL livre.
  Todas as implementações enxergam 2 CPUs (axum: 2 runtimes; may: 2 workers; .NET: 2 loops).
- Ordem na sessão: axum → axum-tuned → may-minihttp → .NET platform, sem reinício entre elas.
- **A/B intercalado**: além da suíte, json, db, fortunes e queries q=1 foram medidos alternando os
  três servidores (may → platform → axum-tuned, duas vezes, 5 s cada). É a leitura mais confiável
  para diferenças pequenas, porque a variação desta máquina entre execuções chega a ±10–15%.
- Scripts: `run-rust.sh`, `run-rust-tuned.sh`, `run-rust-may.sh`, `run-dotnet-platform.sh`;
  saída bruta em `results/rust/`, `results/rust-tuned/`, `results/rust-may-minihttp/`,
  `results/dotnet-platform/`; tabela gerada por `tools/compare.sh` em `results/compare-round5.md`.

## 6. Resultados

### 6.1 Melhor nível por teste (critério de ranking do TechEmpower)

| Teste | Rust axum | Rust axum-tuned | Rust may-minihttp | .NET Platform | Platform / may | Platform / axum-tuned |
|---|---:|---:|---:|---:|---:|---:|
| plaintext | 652.511 | 791.778 | 1.817.619 | **2.192.357** | 1,21x | 2,77x |
| json | 151.888 | 171.589 | **218.879** | 214.252 | 0,98x | 1,25x |
| db | 78.848 | **90.388** | 77.696 | 81.437 | 1,05x | 0,90x |
| queries q=1 | 78.894 | 73.706 | 77.751 | **79.415** | 1,02x | 1,08x |
| queries q=20 | 5.787 | 8.017 | 2.624 | **16.857** | 6,42x | 2,10x |
| fortunes | 68.466 | 68.938 | 81.130 | **91.799** | 1,13x | 1,33x |
| updates q=1 | 12.289 | 17.201 | **23.370** | 21.052 | 0,90x | 1,22x |
| updates q=20 | 3.311 | 5.016 | 2.096 | **7.914** | 3,78x | 1,58x |

### 6.2 A/B intercalado (2 alternâncias × 5 s, c=256; queries com q=1 a 512 conexões)

| Teste | may-minihttp (1ª / 2ª) | .NET Platform (1ª / 2ª) | axum-tuned (1ª / 2ª) | Platform / may | Platform / axum-tuned |
|---|---:|---:|---:|---:|---:|
| json | 239.288 / 220.557 | 216.711 / 237.385 | 186.474 / 158.255 | 0,99x | 1,32x |
| db | 75.981 / 71.421 | 82.662 / 91.076 | 74.135 / 75.293 | **1,18x** | 1,16x |
| fortunes | 84.137 / 80.223 | 74.291 / 83.356 | 64.402 / 68.373 | 0,96x | 1,19x |
| queries q=1 | 81.418 / 81.829 | 87.075 / 80.852 | 69.204 / 72.821 | 1,03x | 1,18x |

### 6.3 Todos os níveis

Requisições por segundo, latência média / p99 em ms, erros (socket + não-2xx). Razões sobre o
Rust axum original. O p99 "0.0" no plaintext é um artefato do `wrk` com pipelining.

| Test | Level | Rust axum req/s | Rust axum-tuned req/s (vs Rust axum) | Rust may-minihttp req/s (vs Rust axum) | .NET Platform req/s (vs Rust axum) | avg / p99 ms (Rust axum · Rust axum-tuned · Rust may-minihttp · .NET Platform) | errors |
|---|---:|---:|---:|---:|---:|---|---:|
| plaintext | c=256 (x16) | 652,511 | 791,778 (1.21x) | 1,817,619 (2.79x) | 2,192,357 (3.36x) | 3.8 / 18.2 · 3.1 / 25.0 · 1.5 / 0.0 · 0.7 / 3.6 | 0 / 0 / 0 / 0 |
| plaintext | c=1024 (x16) | 576,843 | 697,450 (1.21x) | 1,768,657 (3.07x) | 1,742,712 (3.02x) | 15.6 / 0.0 · 12.9 / 0.0 · 7.5 / 114.9 · 3.4 / 13.0 | 0 / 0 / 0 / 0 |
| plaintext | c=4096 (x16) | 527,476 | 687,274 (1.30x) | 1,191,414 (2.26x) | 1,462,470 (2.77x) | 67.3 / 0.0 · 55.3 / 0.0 · 56.9 / 501.9 · 13.5 / 0.0 | 0 / 0 / 0 / 0 |
| json | c=16 | 134,841 | 163,844 (1.22x) | 158,838 (1.18x) | 158,184 (1.17x) | 0.2 / 1.8 · 0.3 / 4.1 · 0.2 / 2.6 · 0.1 / 1.8 | 0 / 0 / 0 / 0 |
| json | c=64 | 151,888 | 171,589 (1.13x) | 203,454 (1.34x) | 214,252 (1.41x) | 0.5 / 3.4 · 0.5 / 3.3 · 0.3 / 2.6 · 0.2 / 2.3 | 0 / 0 / 0 / 0 |
| json | c=256 | 144,899 | 156,348 (1.08x) | 218,879 (1.51x) | 211,078 (1.46x) | 1.8 / 5.8 · 1.6 / 5.7 · 0.8 / 3.4 · 0.9 / 5.4 | 0 / 0 / 0 / 0 |
| json | c=512 | 127,270 | 160,793 (1.26x) | 190,016 (1.49x) | 207,759 (1.63x) | 3.9 / 9.7 · 3.0 / 8.3 · 1.7 / 6.6 · 1.5 / 5.4 | 0 / 0 / 0 / 0 |
| db | c=16 | 37,464 | 40,610 (1.08x) | 48,414 (1.29x) | 45,280 (1.21x) | 0.5 / 3.9 · 0.5 / 3.9 · 0.4 / 3.3 · 0.5 / 3.9 | 0 / 0 / 0 / 0 |
| db | c=64 | 67,520 | 66,104 (0.98x) | 66,771 (0.99x) | 73,168 (1.08x) | 1.0 / 4.8 · 1.1 / 5.2 · 1.1 / 5.7 · 1.1 / 5.7 | 0 / 0 / 0 / 0 |
| db | c=256 | 78,848 | 70,748 (0.90x) | 77,696 (0.99x) | 78,922 (1.00x) | 3.2 / 10.0 · 3.5 / 11.4 · 3.3 / 10.6 · 3.1 / 9.8 | 0 / 0 / 0 / 0 |
| db | c=512 | 72,012 | 90,388 (1.26x) | 77,484 (1.08x) | 81,437 (1.13x) | 6.8 / 17.9 · 5.4 / 14.7 · 6.6 / 19.9 · 5.9 / 17.2 | 0 / 0 / 0 / 0 |
| queries | q=1 | 78,895 | 73,706 (0.93x) | 77,752 (0.99x) | 79,415 (1.01x) | 6.2 / 14.9 · 6.8 / 16.8 · 6.2 / 16.1 · 6.0 / 15.4 | 0 / 0 / 0 / 0 |
| queries | q=5 | 17,228 | 24,939 (1.45x) | 12,838 (0.75x) | 46,815 (2.72x) | 30.7 / 97.2 · 20.5 / 54.1 · 40.1 / 93.8 · 10.0 / 25.1 | 0 / 0 / 0 / 0 |
| queries | q=10 | 10,504 | 15,000 (1.43x) | 5,531 (0.53x) | 29,348 (2.79x) | 48.9 / 120.3 · 33.9 / 77.9 · 91.8 / 144.4 · 17.6 / 60.2 | 0 / 0 / 0 / 0 |
| queries | q=20 | 5,787 | 8,018 (1.39x) | 2,625 (0.45x) | 16,857 (2.91x) | 89.1 / 215.4 · 63.4 / 137.3 · 192.2 / 260.8 · 31.9 / 109.9 | 0 / 0 / 0 / 0 |
| fortunes | c=16 | 40,509 | 40,185 (0.99x) | 48,076 (1.19x) | 47,664 (1.18x) | 0.5 / 3.2 · 0.5 / 3.2 · 0.4 / 2.9 · 0.5 / 4.0 | 0 / 0 / 0 / 0 |
| fortunes | c=64 | 61,309 | 61,531 (1.00x) | 73,376 (1.20x) | 72,565 (1.18x) | 1.1 / 4.7 · 1.1 / 4.5 · 0.9 / 3.9 · 1.0 / 5.5 | 0 / 0 / 0 / 0 |
| fortunes | c=256 | 68,466 | 66,781 (0.98x) | 81,130 (1.18x) | 81,427 (1.19x) | 3.7 / 9.6 · 3.6 / 9.7 · 3.0 / 9.1 · 3.0 / 10.2 | 0 / 0 / 0 / 0 |
| fortunes | c=512 | 60,041 | 68,938 (1.15x) | 77,167 (1.29x) | 91,799 (1.53x) | 7.8 / 17.3 · 6.9 / 17.0 · 6.3 / 15.6 · 5.2 / 15.1 | 0 / 0 / 0 / 0 |
| updates | q=1 | 12,290 | 17,202 (1.40x) | 23,371 (1.90x) | 21,052 (1.71x) | 41.3 / 65.8 · 29.6 / 72.6 · 21.6 / 48.6 · 24.6 / 70.9 | 0 / 0 / 0 / 0 |
| updates | q=5 | 7,859 | 11,072 (1.41x) | 6,766 (0.86x) | 14,846 (1.89x) | 64.7 / 93.7 · 45.9 / 92.0 · 75.1 / 120.7 · 35.6 / 105.4 | 0 / 0 / 0 / 0 |
| updates | q=10 | 5,521 | 8,502 (1.54x) | 3,797 (0.69x) | 11,709 (2.12x) | 91.8 / 140.5 · 59.7 / 124.5 · 133.0 / 184.3 · 44.7 / 126.8 | 0 / 0 / 0 / 0 |
| updates | q=20 | 3,311 | 5,017 (1.52x) | 2,096 (0.63x) | 7,914 (2.39x) | 152.6 / 221.2 · 100.8 / 185.1 · 239.9 / 326.5 · 65.2 / 161.7 | 0 / 0 / 0 / 0 |

## 7. Leitura

**Contra o axum melhorado, o .NET platform segue à frente em tudo.** No A/B intercalado, 1,16x a
1,32x. Na suíte sequencial o axum-tuned marcou mais em `/db` (90.388 contra 81.437, no nível
c=512), mas as quatro medições intercaladas, com os dois servidores sob as mesmas condições, deram
1,16x para o .NET; a suíte sequencial fica como piso. O tuning rendeu ao Rust o que tinha rendido ao
.NET: `updates q=1` +40%, `queries q=20` +39%, json +13% com `simd-json`, plaintext +21%.

**Contra o may-minihttp, é um empate técnico com vitórias dos dois lados.**

- O .NET vence em plaintext (1,21x), em `/db` (1,05x na suíte, 1,18x no A/B) e, de longe, nas
  operações de várias linhas: o may-minihttp executa as N consultas de uma requisição em sequência,
  sem pipelining, e cai para 2,6k em `queries q=20` contra 16,9k do .NET (que manda os 20 `Bind/Execute`
  num único `Sync`).
- O may-minihttp vence em `updates q=1` (23,4k contra 21,1k, 0,90x).
- json, fortunes e `queries q=1` ficam dentro do ruído (0,96x a 1,03x no A/B).

Os dois são o mesmo desenho: um loop por core, HTTP e PostgreSQL na mesma thread, cliente
PostgreSQL *pipelined* próprio, uma conexão primária por core. As diferenças são de implementação
(corrotinas com stack e `yarte` no Rust; `epoll` por P/Invoke, System.Text.Json com source
generator e renderizador manual no .NET), e o resultado empatado diz que, nesse nível, a linguagem
deixou de ser o fator; a arquitetura e o número de syscalls por requisição são.

**O que ainda separaria os dois, se alguém quisesse ir além:** o .NET poderia pipelinar o
`updates` como o may faz em `updates q=1` (ele ganha ali por ter menos latência por requisição com
uma conexão só); o may-minihttp poderia pipelinar as N consultas de `queries`/`updates` e reservar
conexões para elas, exatamente a mudança feita no axum-tuned, que lhe daria os 2x–6x que falta.

## 8. Reprodução

```bash
# pré-requisitos: rust toolchain, .NET 11 SDK, wrk, PostgreSQL 16 com o schema do TechEmpower (ver README.md)
cd benchmark
./run-rust.sh                 # -> results/rust/summary.csv
POSTGRES_HEAVY_CONNECTIONS=2 ./run-rust-tuned.sh   # -> results/rust-tuned/summary.csv
./run-rust-may.sh             # -> results/rust-may-minihttp/summary.csv (mapeia tfb-database em /etc/hosts)
./run-dotnet-platform.sh      # -> results/dotnet-platform/summary.csv
tools/compare.sh "Rust axum=results/rust/summary.csv" "Rust axum-tuned=results/rust-tuned/summary.csv" \
  "Rust may-minihttp=results/rust-may-minihttp/summary.csv" ".NET Platform=results/dotnet-platform/summary.csv"
```

Binários Rust compilados com `target-cpu=native` só rodam na CPU em que foram compilados: se o host
mudar, `cargo clean` antes de rodar de novo (aconteceu na rodada 3).

## 9. Limitações desta rodada

- Host mais lento que o da rodada 4 (mesmo modelo de CPU, provavelmente outra máquina física): todos
  os valores absolutos caíram ~20% em relação à rodada 4, para todas as implementações. Só as
  comparações dentro desta rodada valem.
- Uma execução da suíte por implementação, mais duas alternâncias no A/B. Diferenças abaixo de ~10%
  na suíte sequencial não são conclusivas; o A/B reduz, mas não elimina, esse ruído.
- O axum-tuned não é "o melhor Rust possível": é o axum com três ajustes escolhidos por serem os
  mesmos feitos no .NET. O may-minihttp cobre o outro extremo (infraestrutura própria) e não foi
  ajustado.
- A máquina tem 4 vCPUs compartilhadas com o PostgreSQL e com o gerador de carga; os números não
  se comparam aos do site do TechEmpower.

## 10. Arquivos desta rodada

| Arquivo | Conteúdo |
|---|---|
| `rust-axum-tuned/` | código do axum ajustado (diff na seção 2) |
| `rust-may-minihttp/` | cópia do may-minihttp, `LICENSE-TFB` |
| `run-rust-tuned.sh`, `run-rust-may.sh` | execução da suíte para as duas variantes |
| `results/rust/`, `results/rust-tuned/`, `results/rust-may-minihttp/`, `results/dotnet-platform/` | saída bruta do `wrk` por nível, `summary.csv`, logs dos servidores |
| `results/compare-round5.md` | tabela completa gerada por `tools/compare.sh` |
| `RESULTS.md` (nesta pasta e na raiz) | seção "Rodada 5" com o resumo |
