#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

use std::io;
use std::sync::Arc;

use bytes::BytesMut;
use may_minihttp::{HttpService, HttpServiceFactory, Request, Response};
use may_postgres::{Client, Statement};
use nanorand::{Rng, WyRand};
use smallvec::SmallVec;
use yarte::{ywrite_html, Serialize};

mod utils {
    use atoi::FromRadix10;

    pub fn get_query_param(query: &str) -> u16 {
        let q = if let Some(pos) = query.find("?q") {
            u16::from_radix_10(query.split_at(pos + 3).1.as_ref()).0
        } else {
            1
        };
        q.clamp(1, 500)
    }
}

#[derive(Serialize)]
struct HelloMessage {
    message: &'static str,
}

#[derive(Serialize)]
struct WorldRow {
    id: i32,
    randomnumber: i32,
}

#[derive(Serialize)]
pub struct Fortune<'a> {
    id: i32,
    message: &'a str,
}

struct PgConnectionPool {
    clients: Vec<PgConnection>,
}

impl PgConnectionPool {
    fn new(db_url: &'static str, size: usize) -> PgConnectionPool {
        let clients = (0..size)
            .map(|_| may::go!(move || PgConnection::new(db_url)))
            .collect::<Vec<_>>();
        let mut clients: Vec<_> = clients.into_iter().map(|t| t.join().unwrap()).collect();
        clients.sort_by(|a, b| (a.client.id() % size).cmp(&(b.client.id() % size)));
        PgConnectionPool { clients }
    }

    fn get_connection(&self, id: usize) -> PgConnection {
        let len = self.clients.len();
        let connection = &self.clients[id % len];
        // assert_eq!(connection.client.id() % len, id % len);
        PgConnection {
            client: connection.client.clone(),
            statement: connection.statement.clone(),
        }
    }
}

struct PgStatement {
    world: Statement,
    world_many: Statement,
    update_many: Statement,
    fortune: Statement,
}

struct PgConnection {
    client: Client,
    statement: Arc<PgStatement>,
}

impl PgConnection {
    fn new(db_url: &str) -> Self {
        let client = may_postgres::connect(db_url).unwrap();

        let world = client.prepare("SELECT * FROM world WHERE id=$1").unwrap();
        let world_many = client
            .prepare("SELECT id, randomnumber FROM world WHERE id = ANY($1)")
            .unwrap();
        let update_many = client
            .prepare("UPDATE world SET randomnumber = v.rn FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) AS w(id, rn)) AS v(id, rn) WHERE world.id = v.id")
            .unwrap();
        let fortune = client.prepare("SELECT * FROM fortune").unwrap();

        let statement = Arc::new(PgStatement {
            world,
            world_many,
            update_many,
            fortune,
        });

        PgConnection { client, statement }
    }

    fn get_world(&self, random_id: i32) -> Result<WorldRow, may_postgres::Error> {
        let mut q = self
            .client
            .query_raw(&self.statement.world, &[&random_id])?;
        match q.next().transpose()? {
            Some(row) => Ok(WorldRow {
                id: row.get(0),
                randomnumber: row.get(1),
            }),
            None => unreachable!("random_id={}", random_id),
        }
    }

    fn get_worlds(
        &self,
        num: usize,
        rand: &mut WyRand,
    ) -> Result<SmallVec<[WorldRow; 32]>, may_postgres::Error> {
        // Uma consulta por requisicao (ANY) em vez de N consultas pipelined: e o mesmo desenho do fast7 do Zig.
        // Ids repetidos sao deduplicados porque o ANY devolve a linha uma vez so.
        let mut ids: Vec<i32> = Vec::with_capacity(num);
        for _ in 0..num {
            ids.push((rand.generate::<u32>() % 10_000 + 1) as i32);
        }
        ids.sort_unstable();
        ids.dedup();

        let mut q = self.client.query_raw(&self.statement.world_many, &[&ids])?;
        let mut worlds = SmallVec::<[WorldRow; 32]>::new();
        while let Some(row) = q.next().transpose()? {
            worlds.push(WorldRow {
                id: row.get(0),
                randomnumber: row.get(1),
            });
        }
        Ok(worlds)
    }

    fn updates(
        &self,
        num: usize,
        rand: &mut WyRand,
    ) -> Result<SmallVec<[WorldRow; 32]>, may_postgres::Error> {
        // Um UPDATE em lote por requisicao (UNNEST), com ids ordenados para dois lotes concorrentes nao se
        // travarem; ids repetidos ficam com o ultimo numero sorteado. Mesmo desenho do fast7 do Zig.
        let mut pares: Vec<(i32, i32)> = Vec::with_capacity(num);
        for _ in 0..num {
            pares.push((
                (rand.generate::<u32>() % 10_000 + 1) as i32,
                (rand.generate::<u32>() % 10_000 + 1) as i32,
            ));
        }
        pares.sort_unstable_by_key(|p| p.0);
        pares.dedup_by_key(|p| p.0);
        let (ids, nums): (Vec<i32>, Vec<i32>) = pares.into_iter().unzip();

        let mut q = self.client.query_raw(&self.statement.update_many, &[&ids, &nums])?;
        while q.next().transpose()?.is_some() {}

        Ok(ids
            .into_iter()
            .zip(nums)
            .map(|(id, randomnumber)| WorldRow { id, randomnumber })
            .collect())
    }

    fn tell_fortune(&self, buf: &mut BytesMut) -> Result<(), may_postgres::Error> {
        let rows = self.client.query_raw(&self.statement.fortune, &[])?;

        let all_rows = Vec::from_iter(rows.map(|r| r.unwrap()));
        let mut fortunes = Vec::with_capacity(all_rows.len() + 1);
        fortunes.extend(all_rows.iter().map(|r| Fortune {
            id: r.get(0),
            message: r.get(1),
        }));
        fortunes.push(Fortune {
            id: 0,
            message: "Additional fortune added at request time.",
        });
        fortunes.sort_by(|it, next| it.message.cmp(next.message));

        let mut body = unsafe { std::ptr::read(buf) };
        ywrite_html!(body, "{{> fortune }}");
        unsafe { std::ptr::write(buf, body) };
        Ok(())
    }
}

struct Techempower {
    db: PgConnection,
    rng: WyRand,
}

impl HttpService for Techempower {
    fn call(&mut self, req: Request, rsp: &mut Response) -> io::Result<()> {
        // Bare-bones router
        match req.path() {
            "/json" => {
                rsp.header("Content-Type: application/json");
                let msg = HelloMessage {
                    message: "Hello, World!",
                };
                msg.to_bytes_mut(rsp.body_mut());
            }
            "/plaintext" => {
                rsp.header("Content-Type: text/plain").body("Hello, World!");
            }
            "/db" => {
                rsp.header("Content-Type: application/json");
                let random_id = (self.rng.generate::<u32>() % 10_000 + 1) as i32;
                let world = self.db.get_world(random_id).unwrap();
                world.to_bytes_mut(rsp.body_mut())
            }
            "/fortunes" => {
                rsp.header("Content-Type: text/html; charset=utf-8");
                self.db.tell_fortune(rsp.body_mut()).unwrap();
            }
            p if p.starts_with("/queries") => {
                rsp.header("Content-Type: application/json");
                let q = utils::get_query_param(p) as usize;
                let worlds = self.db.get_worlds(q, &mut self.rng).unwrap();
                worlds.to_bytes_mut(rsp.body_mut());
            }
            p if p.starts_with("/updates") => {
                rsp.header("Content-Type: application/json");
                let q = utils::get_query_param(p) as usize;
                let worlds = self.db.updates(q, &mut self.rng).unwrap();
                worlds.to_bytes_mut(rsp.body_mut());
            }
            _ => {
                rsp.status_code(404, "Not Found");
            }
        }

        Ok(())
    }
}

struct HttpServer {
    db_pool: PgConnectionPool,
}

impl HttpServiceFactory for HttpServer {
    type Service = Techempower;

    fn new_service(&self, id: usize) -> Self::Service {
        let db = self.db_pool.get_connection(id);
        let rng = WyRand::new();
        Techempower { db, rng }
    }
}

fn main() {
    may::config().set_pool_capacity(1000).set_stack_size(0x1000);
    println!("Starting http server: 0.0.0.1:8080");
    let server = HttpServer {
        db_pool: PgConnectionPool::new(
            "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world",
            num_cpus::get(),
        ),
    };
    server.start("0.0.0.0:18084").unwrap().join().unwrap();
}
