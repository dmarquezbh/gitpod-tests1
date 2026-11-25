## Nim "platform" fast path: sockets POSIX com SO_REUSEPORT por thread + libpq por thread.
## Keep-alive e pipelining tratados no próprio loop (sem framework HTTP).
import std/[net, os, posix, random, strutils, tables, times, algorithm]

type PGconn {.importc, header: "<libpq-fe.h>".} = object
{.push header: "<libpq-fe.h>".}
proc PQconnectdb(cs: cstring): ptr PGconn {.importc.}
proc PQexec(c: ptr PGconn, q: cstring): pointer {.importc.}
proc PQntuples(r: pointer): cint {.importc.}
proc PQgetvalue(r: pointer; i, j: cint): cstring {.importc.}
proc PQclear(r: pointer) {.importc.}
{.pop.}

const Porta = 18095
const Conn = "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world"

proc texto(r: pointer; i, j: int): string =
  let p = PQgetvalue(r, i.cint, j.cint)
  if p == nil: return ""
  var n = 0
  while p[n] != '\0': inc n
  result = newString(n)
  if n > 0: copyMem(addr result[0], p, n)

proc consulta(db: ptr PGconn; sql: string): seq[(int, int)] =
  let r = PQexec(db, cstring(sql))
  if r == nil: return @[]
  defer: PQclear(r)
  for i in 0 ..< int(PQntuples(r)):
    result.add (parseInt(texto(r, i, 0)), parseInt(texto(r, i, 1)))

proc esc(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add c

proc fortunesHtml(db: ptr PGconn): string =
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
    result.add "<tr><td>" & $p[0] & "</td><td>" & esc(p[1]) & "</td></tr>"
  result.add "</table></body></html>"

proc qtdAlvo(alvo: string): int =
  let i = alvo.find("q=")
  if i < 0: return 1
  var n = 0
  for c in alvo[i + 2 .. ^1]:
    if c notin {'0'..'9'}: break
    n = n * 10 + (ord(c) - ord('0'))
  max(1, min(500, n))

proc cabecalho(tipo: string; n: int): string =
  "HTTP/1.1 200 OK\r\nContent-Type: " & tipo & "\r\nContent-Length: " & $n & "\r\n\r\n"

proc tratar(db: ptr PGconn; alvo: string; saida: var string) =
  if alvo == "/plaintext":
    saida = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!"
  elif alvo == "/json":
    let corpo = "{\"message\":\"Hello, World!\"}"
    saida = cabecalho("application/json", corpo.len) & corpo
  elif alvo == "/db":
    let id = rand(1..10000)
    let r = consulta(db, "SELECT id, randomnumber FROM world WHERE id = " & $id)
    let corpo = "{\"id\":" & $r[0][0] & ",\"randomNumber\":" & $r[0][1] & "}"
    saida = cabecalho("application/json", corpo.len) & corpo
  elif alvo.startsWith("/queries"):
    let q = qtdAlvo(alvo)
    var ids: seq[string] = @[]
    for _ in 0 ..< q: ids.add $(rand(1..10000))
    let r = consulta(db, "SELECT id, randomnumber FROM world WHERE id IN (" & ids.join(",") & ")")
    var porId = initTable[int, int]()
    for par in r: porId[par[0]] = par[1]
    var partes: seq[string] = @[]
    for id in ids: partes.add "{\"id\":" & id & ",\"randomNumber\":" & $porId.getOrDefault(parseInt(id), 0) & "}"
    let corpo = "[" & partes.join(",") & "]"
    saida = cabecalho("application/json", corpo.len) & corpo
  elif alvo.startsWith("/updates"):
    let q = qtdAlvo(alvo)
    var ids: seq[int] = @[]
    var novos: seq[int] = @[]
    for _ in 0 ..< q:
      ids.add rand(1..10000); novos.add rand(1..10000)
    var pares: seq[string] = @[]
    for i in 0 ..< ids.len: pares.add "(" & $ids[i] & "," & $novos[i] & ")"
    let r = consulta(db, "UPDATE world SET randomnumber = v.rn FROM (VALUES " & pares.join(",") &
                     ") AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber")
    var porId = initTable[int, int]()
    for par in r: porId[par[0]] = par[1]
    var partes: seq[string] = @[]
    for i in 0 ..< ids.len:
      partes.add "{\"id\":" & $ids[i] & ",\"randomNumber\":" & $porId.getOrDefault(ids[i], novos[i]) & "}"
    let corpo = "[" & partes.join(",") & "]"
    saida = cabecalho("application/json", corpo.len) & corpo
  elif alvo == "/fortunes":
    let corpo = fortunesHtml(db)
    saida = cabecalho("text/html; charset=utf-8", corpo.len) & corpo
  else:
    saida = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"

proc escuta(): SocketHandle =
  let s = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0)
  var um: cint = 1
  discard setsockopt(s, posix.SOL_SOCKET, posix.SO_REUSEADDR, addr um, sizeof(um).SockLen)
  when defined(linux):
    discard setsockopt(s, posix.SOL_SOCKET, posix.SO_REUSEPORT, addr um, sizeof(um).SockLen)
  var sa: posix.Sockaddr_in
  sa.sin_family = posix.AF_INET.uint16
  sa.sin_port = htons(Porta.uint16)
  sa.sin_addr.s_addr = 0
  if posix.bindSocket(s, cast[ptr posix.SockAddr](addr sa), sizeof(sa).SockLen) != 0:
    quit "bind falhou", 1
  if posix.listen(s, 4096) != 0: quit "listen falhou", 1
  s

proc trabalho() {.thread.} =
  randomize()
  let db = PQconnectdb(cstring(Conn))
  if db == nil: quit "libpq: sem conexao", 1
  let ls = escuta()
  var buf = newString(65536)
  var saida = newStringOfCap(8192)
  while true:
    let cliente = posix.accept(ls, nil, nil)
    if cliente < 0: continue
    while true:
      let n = posix.recv(cliente, addr buf[0], buf.len, 0)
      if n <= 0: break
      var pos = 0
      while pos < n:
        let fim = buf.find("\r\n\r\n", pos)
        if fim < 0: break
        let linhaFim = buf.find("\r\n", pos)
        let linha = buf[pos ..< linhaFim]
        let partes = linha.split(' ')
        if partes.len < 2: break
        tratar(db, partes[1], saida)
        var enviado = 0
        while enviado < saida.len:
          let k = posix.send(cliente, addr saida[enviado], saida.len - enviado, 0)
          if k <= 0: break
          enviado += k
        pos = fim + 4
    discard posix.close(cliente)

var threads: array[2, Thread[void]]
for i in 0 ..< threads.len:
  createThread(threads[i], trabalho)
joinThreads(threads)
