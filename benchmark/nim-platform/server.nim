## Nim "platform" entry: httpbeast (event loop) + libpq direto, os seis testes.
import httpbeast, options, os, random, strutils, tables, algorithm, asyncdispatch

type PGconn {.importc, header: "<libpq-fe.h>".} = object
{.push header: "<libpq-fe.h>".}
proc PQconnectdb(cs: cstring): ptr PGconn {.importc.}
proc PQexec(c: ptr PGconn, q: cstring): pointer {.importc.}
proc PQntuples(r: pointer): cint {.importc.}
proc PQgetvalue(r: pointer; i, j: cint): cstring {.importc.}
proc PQclear(r: pointer) {.importc.}
{.pop.}

const Conn = "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world"
var db: ptr PGconn

proc texto(r: pointer; i, j: int): string =
  let p = PQgetvalue(r, i.cint, j.cint)
  if p == nil: return ""
  var n = 0
  while p[n] != '\0': inc n
  result = newString(n)
  if n > 0: copyMem(addr result[0], p, n)

proc consulta(sql: string): seq[(int, int)] =
  let r = PQexec(db, cstring(sql))
  if r == nil: return @[]
  defer: PQclear(r)
  for i in 0 ..< int(PQntuples(r)):
    result.add (parseInt(texto(r, i, 0)), parseInt(texto(r, i, 1)))

proc fortunesHtml(): string =
  let r = PQexec(db, cstring("SELECT id, message FROM fortune"))
  var pares: seq[(int, string)] = @[]
  if r != nil:
    for i in 0 ..< int(PQntuples(r)):
      pares.add (parseInt(texto(r, i, 0)), texto(r, i, 1))
    PQclear(r)
  pares.add (0, "Additional fortune added at request time.")
  algorithm.sort(pares, proc(a, b: (int, string)): int = cmp(a[1], b[1]))
  result = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>"
  for p in pares:
    let msg = p[1].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
    result.add "<tr><td>" & $p[0] & "</td><td>" & msg & "</td></tr>"
  result.add "</table></body></html>"

proc qParam(path: string): int =
  let i = path.find("q=")
  if i < 0: return 1
  var n = 0
  for c in path[i + 2 .. ^1]:
    if c notin {'0'..'9'}: break
    n = n * 10 + (ord(c) - ord('0'))
  max(1, min(500, n))

const Json = "Content-Type: application/json\r\n"
const Html = "Content-Type: text/html; charset=utf-8\r\n"

proc handler(req: Request): Future[void] {.gcsafe.} =
  let p = req.path.get("/")
  if p == "/plaintext":
    req.send(Http200, "Hello, World!", "Content-Type: text/plain\r\n")
  elif p == "/json":
    req.send(Http200, "{\"message\":\"Hello, World!\"}", Json)
  elif p == "/db":
    let id = rand(1..10000)
    let r = consulta("SELECT id, randomnumber FROM world WHERE id = " & $id)
    req.send(Http200, "{\"id\":" & $r[0][0] & ",\"randomNumber\":" & $r[0][1] & "}", Json)
  elif p.startsWith("/queries"):
    let q = qParam(p)
    var ids: seq[int] = @[]
    for _ in 0 ..< q: ids.add rand(1..10000)
    var lista: seq[string] = @[]
    for id in ids: lista.add $id
    let r = consulta("SELECT id, randomnumber FROM world WHERE id IN (" & lista.join(",") & ")")
    var porId = initTable[int, int]()
    for par in r: porId[par[0]] = par[1]
    var partes: seq[string] = @[]
    for id in ids: partes.add "{\"id\":" & $id & ",\"randomNumber\":" & $porId.getOrDefault(id, 0) & "}"
    req.send(Http200, "[" & partes.join(",") & "]", Json)
  elif p.startsWith("/updates"):
    let q = qParam(p)
    var ids: seq[int] = @[]
    var novos: seq[int] = @[]
    for _ in 0 ..< q:
      ids.add rand(1..10000); novos.add rand(1..10000)
    var paresSql: seq[string] = @[]
    for i in 0 ..< ids.len: paresSql.add "(" & $ids[i] & "," & $novos[i] & ")"
    let r = consulta("UPDATE world SET randomnumber = v.rn FROM (VALUES " & paresSql.join(",") &
                     ") AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber")
    var porId = initTable[int, int]()
    for par in r: porId[par[0]] = par[1]
    var partes: seq[string] = @[]
    for i in 0 ..< ids.len:
      partes.add "{\"id\":" & $ids[i] & ",\"randomNumber\":" & $porId.getOrDefault(ids[i], novos[i]) & "}"
    req.send(Http200, "[" & partes.join(",") & "]", Json)
  elif p == "/fortunes":
    req.send(Http200, fortunesHtml(), Html)
  else:
    req.send(Http404, "")

let porta = parseInt(getEnv("PORT", "8095"))
randomize()
db = PQconnectdb(cstring(Conn))
if db == nil: quit "libpq: sem conexão", 1
var s = initSettings(Port(porta))
run(handler, s)
