// TechEmpower-style benchmark server: same source on Node, Bun and Deno.
// node:http + pg (npm). Single process, pg pool of 8.
"use strict";
const http = require("node:http");
const { Pool } = require("pg");

const PORT = parseInt(process.argv[2] || "18087", 10);

const pool = new Pool({
  host: "127.0.0.1",
  port: 5432,
  user: "benchmarkdbuser",
  password: "benchmarkdbpass",
  database: "hello_world",
  max: 8,
});

const rnd = () => 1 + Math.floor(Math.random() * 10000);
const clampQ = (v) => Math.max(1, Math.min(500, parseInt(v, 10) || 1));

function escapeHtml(s) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#x27;")
    .replace(/\//g, "&#x2F;");
}

async function world(rn) {
  const r = await pool.query("SELECT id, randomnumber FROM world WHERE id = $1", [rn]);
  return { id: r.rows[0].id, randomNumber: r.rows[0].randomnumber };
}

async function fortunes() {
  const r = await pool.query("SELECT id, message FROM fortune");
  const rows = r.rows.map((x) => ({ id: x.id, message: x.message }));
  rows.push({ id: 0, message: "Additional fortune added at request time." });
  rows.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
  let body =
    "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>" +
    "<tr><th>id</th><th>message</th></tr>";
  for (const row of rows) body += `<tr><td>${row.id}</td><td>${escapeHtml(row.message)}</td></tr>`;
  return body + "</table></body></html>";
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  let body;
  let type = "text/plain";
  try {
    switch (url.pathname) {
      case "/plaintext":
        body = "Hello, World!";
        break;
      case "/json":
        body = '{"message":"Hello, World!"}';
        type = "application/json";
        break;
      case "/db":
        body = JSON.stringify(await world(rnd()));
        type = "application/json";
        break;
      case "/queries": {
        const q = clampQ(url.searchParams.get("q") || url.searchParams.get("queries"));
        const out = [];
        for (let i = 0; i < q; i++) out.push(await world(rnd()));
        body = JSON.stringify(out);
        type = "application/json";
        break;
      }
      case "/updates": {
        const q = clampQ(url.searchParams.get("q") || url.searchParams.get("queries"));
        const out = [];
        for (let i = 0; i < q; i++) {
          const w = await world(rnd());
          const newRn = rnd();
          await pool.query("UPDATE world SET randomnumber = $1 WHERE id = $2", [newRn, w.id]);
          out.push({ id: w.id, randomNumber: newRn });
        }
        body = JSON.stringify(out);
        type = "application/json";
        break;
      }
      case "/fortunes":
        body = await fortunes();
        type = "text/html; charset=utf-8";
        break;
      default:
        res.writeHead(404, { "Content-Type": "text/plain" });
        res.end("Not Found");
        return;
    }
  } catch (e) {
    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end("error");
    return;
  }
  res.writeHead(200, { "Content-Type": type, "Content-Length": Buffer.byteLength(body) });
  res.end(body);
});

server.keepAliveTimeout = 65000;
server.listen(PORT, "0.0.0.0", 4096, () => {
  console.log(`started JS server on port ${PORT}`);
});
