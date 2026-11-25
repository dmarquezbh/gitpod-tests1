"""CPython "platform" HTTP server with its own epoll loop (all six TechEmpower tests).

Same idea as dotnet-platform's EventLoop/: no asyncio, no uvloop, no HTTP library. Standard
library for the network path, and libpq (the same C client the .NET platform entry uses) via
ctypes for db/queries/fortunes/updates — no Python driver in the hot path.

- One process per CPU in the affinity mask, each with its own SO_REUSEPORT listening socket and
  its own epoll instance. The parent creates the sockets before forking and keeps them open, so
  the pid run-suite.sh starts is the one holding the listener.
- One shared receive buffer per process (recv_into, no allocation per read). A partial request
  left at the end of a read is copied to the connection and joined with the next read.
- Pipelining: every complete request in a read is answered with a single send().
- Request fast path: the bytes of the last parsed request are kept, and the next request is first
  compared against them (one memcmp). Only plaintext/json use it — db/queries/fortunes/updates
  must re-run for every request.
- /json serializes per request (a TechEmpower rule) with the stdlib json module.
- /fortunes: rows from PostgreSQL plus the extra fortune, sorted by message, HTML-escaped.
- Backpressure: on a short send() the rest is queued and the connection is not read again until
  the queue is flushed.

Assumed limitations (same as the platform entries): HTTP/1.1 only, GET without a body, no TLS.
"""
import ctypes
import ctypes.util
import gc
import html
import json
import os
import random
import select
import signal
import socket
import sys
from email.utils import formatdate
from time import monotonic

PORT = int(os.environ.get("PORT", "8080"))
WORKERS = int(os.environ.get("WORKERS", "0")) or len(os.sched_getaffinity(0))
FAST_PATH = os.environ.get("FAST_PATH", "1") == "1"
DB_URL = os.environ.get("DB_URL", "postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world")
MAX_Q = 500

_dumps = json.JSONEncoder(separators=(",", ":")).encode
_LEN = tuple(str(i).encode() + b"\r\n\r\n" for i in range(1024))


def _cl(n):
    """Content-Length + fim de cabeçalho, pré-computado até 1023 bytes."""
    return _LEN[n] if n < 1024 else str(n).encode() + b"\r\n\r\n"

EPOLLIN, EPOLLOUT = select.EPOLLIN, select.EPOLLOUT
PLAIN, JSON_, DB, QUERIES, FORTUNES, UPDATES, NOTFOUND = range(7)
FAST_KINDS = (PLAIN, JSON_)

# ── libpq via ctypes ────────────────────────────────────────────────────────────────────────────
_pq = ctypes.CDLL(ctypes.util.find_library("pq") or "libpq.so.5")
_pq.PQconnectdb.restype = ctypes.c_void_p
_pq.PQconnectdb.argtypes = [ctypes.c_char_p]
_pq.PQstatus.argtypes = [ctypes.c_void_p]
_pq.PQstatus.restype = ctypes.c_int
_pq.PQerrorMessage.argtypes = [ctypes.c_void_p]
_pq.PQerrorMessage.restype = ctypes.c_char_p
_pq.PQprepare.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
_pq.PQprepare.restype = ctypes.c_void_p
_pq.PQexecPrepared.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p),
                               ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
_pq.PQexecPrepared.restype = ctypes.c_void_p
_pq.PQexec.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_pq.PQexec.restype = ctypes.c_void_p
_pq.PQntuples.argtypes = [ctypes.c_void_p]
_pq.PQntuples.restype = ctypes.c_int
_pq.PQgetvalue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
_pq.PQgetvalue.restype = ctypes.c_char_p
_pq.PQclear.argtypes = [ctypes.c_void_p]
_pq.PQreset.argtypes = [ctypes.c_void_p]

SQL_SEL = b"SELECT id, randomnumber FROM world WHERE id = $1"
SQL_UPD = b"UPDATE world SET randomnumber = $1 WHERE id = $2"
SQL_STMTS = (
    (b"sel", SQL_SEL),
    (b"upd", SQL_UPD),
    (b"sell", b"SELECT id, randomnumber FROM world WHERE id = ANY($1::int[])"),
    (b"updm", b"UPDATE world SET randomnumber = v.rn FROM unnest($1::int[], $2::int[]) AS v(id, rn) "
              b"WHERE world.id = v.id RETURNING world.id, world.randomnumber"),
)
_rand = random.randrange


class Db:
    def __init__(self, url):
        self.conn = _pq.PQconnectdb(url.encode())
        if not self.conn or _pq.PQstatus(self.conn) != 0:
            raise RuntimeError("libpq: " + (_pq.PQerrorMessage(self.conn) or b"").decode(errors="replace"))
        for nome, sql in SQL_STMTS:
            _pq.PQclear(_pq.PQprepare(self.conn, nome, sql, 0, None))
        self.sel, self.upd = b"sel", b"upd"

    def reset(self):
        _pq.PQreset(self.conn)
        for nome, sql in SQL_STMTS:
            _pq.PQclear(_pq.PQprepare(self.conn, nome, sql, 0, None))

    def select(self, rid):
        param = (ctypes.c_char_p * 1)(str(rid).encode())
        res = _pq.PQexecPrepared(self.conn, self.sel, 1, param, None, None, 0)
        try:
            if _pq.PQntuples(res) != 1:
                return (rid, 0)
            pv = _pq.PQgetvalue
            return (int(pv(res, 0, 0)), int(pv(res, 0, 1)))
        finally:
            _pq.PQclear(res)

    def update(self, rid, novo):
        params = (ctypes.c_char_p * 2)(str(novo).encode(), str(rid).encode())
        res = _pq.PQexecPrepared(self.conn, self.upd, 2, params, None, None, 0)
        _pq.PQclear(res)

    def select_many(self, ids):
        # SELECT ... WHERE id = ANY($1) devolve as linhas em qualquer ordem; reordena pelo pedido.
        arr = "{" + ",".join(map(str, ids)) + "}"
        param = (ctypes.c_char_p * 1)(arr.encode())
        res = _pq.PQexecPrepared(self.conn, b"sell", 1, param, None, None, 0)
        try:
            pv = _pq.PQgetvalue
            por_id = {int(pv(res, i, 0)): int(pv(res, i, 1)) for i in range(_pq.PQntuples(res))}
            return [(rid, por_id[rid]) for rid in ids]
        finally:
            _pq.PQclear(res)

    def update_many(self, ids, novos):
        arr = "{" + ",".join(map(str, ids)) + "}"
        arrn = "{" + ",".join(map(str, novos)) + "}"
        params = (ctypes.c_char_p * 2)(arr.encode(), arrn.encode())
        res = _pq.PQexecPrepared(self.conn, b"updm", 2, params, None, None, 0)
        try:
            pv = _pq.PQgetvalue
            por_id = {int(pv(res, i, 0)): int(pv(res, i, 1)) for i in range(_pq.PQntuples(res))}
            return [(rid, por_id.get(rid, novo)) for rid, novo in zip(ids, novos)]
        finally:
            _pq.PQclear(res)

    def fortunes(self):
        res = _pq.PQexec(self.conn, b"SELECT id, message FROM fortune")
        try:
            pv = _pq.PQgetvalue
            return [(int(pv(res, i, 0)), pv(res, i, 1).decode("utf-8")) for i in range(_pq.PQntuples(res))]
        finally:
            _pq.PQclear(res)


# ── respostas ──────────────────────────────────────────────────────────────────────────────────
def _responses():
    date = formatdate(usegmt=True).encode()
    common = b"Server: py\r\nDate: " + date + b"\r\n"
    plain = (b"HTTP/1.1 200 OK\r\n" + common +
             b"Content-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!")
    json_head = b"HTTP/1.1 200 OK\r\n" + common + b"Content-Type: application/json\r\nContent-Length: "
    html_head = b"HTTP/1.1 200 OK\r\n" + common + b"Content-Type: text/html; charset=utf-8\r\nContent-Length: "
    notfound = b"HTTP/1.1 404 Not Found\r\n" + common + b"Content-Length: 0\r\n\r\n"
    return plain, json_head, html_head, notfound


def _listen_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("0.0.0.0", PORT))
    s.listen(4096)
    s.setblocking(False)
    return s


def _q_param(target, chave=b"q"):
    """Lê ?q=N (ou ?queries=N) do target e prende em 1..MAX_Q."""
    i = target.find(b"?" + chave + b"=")
    if i < 0:
        i = target.find(b"&" + chave + b"=")
        if i < 0:
            return 1
        i += 1
    else:
        i += 1
    ini = i + len(chave) + 1
    fim = ini
    n = len(target)
    while fim < n and 48 <= target[fim] <= 57:
        fim += 1
    if fim == ini:
        return 1
    return max(1, min(MAX_Q, int(target[ini:fim])))


def _fortunes_html(rows):
    extra = (0, "Additional fortune added at request time.")
    itens = sorted(rows + [extra], key=lambda r: r[1])
    esc = html.escape
    partes = ["<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>"
              "<tr><th>id</th><th>message</th></tr>"]
    for fid, msg in itens:
        partes.append(f"<tr><td>{fid}</td><td>{esc(msg)}</td></tr>")
    partes.append("</table></body></html>")
    return "".join(partes).encode("utf-8")


def _worker(lsock, cpu):
    if cpu is not None:
        os.sched_setaffinity(0, {cpu})
    db = Db(DB_URL)
    ep = select.epoll()
    lfd = lsock.fileno()
    ep.register(lfd, EPOLLIN)
    poll, modify, register, unregister = ep.poll, ep.modify, ep.register, ep.unregister
    accept = lsock.accept

    conns = {}  # fd -> [sock, recv_into, send, pending_in, pending_out]
    buf = bytearray(65536)
    mv = memoryview(buf)
    HALF = len(buf) // 2
    find, startswith = buf.find, buf.startswith
    last_req, last_len, last_kind = b"\x00", 1, NOTFOUND

    plain, json_head, html_head, notfound = _responses()
    next_date = monotonic() + 1.0

    def close(fd, c):
        try:
            unregister(fd)
        except OSError:
            pass
        c[0].close()
        del conns[fd]

    def corpo_db(rid):
        _, rn = db.select(rid)
        return _dumps({"id": rid, "randomNumber": rn}).encode()

    def corpo_queries(q):
        # Uma única ida ao banco por requisição (ANY), como o batching do dotnet-platform.
        ids = [_rand(1, 10001) for _ in range(q)]
        return ("[" + ",".join('{"id":%d,"randomNumber":%d}' % (rid, rn)
                               for rid, rn in db.select_many(ids)) + "]").encode()

    def corpo_updates(q):
        # Ids e novos valores escolhidos no cliente; um único UPDATE com arrays.
        ids = [_rand(1, 10001) for _ in range(q)]
        novos = [_rand(1, 10001) for _ in ids]
        return ("[" + ",".join('{"id":%d,"randomNumber":%d}' % (rid, novo)
                               for rid, novo in db.update_many(ids, novos)) + "]").encode()

    gc.collect()
    gc.freeze()  # startup objects never get rescanned by the cyclic GC

    while True:
        events = poll(1.0)
        if monotonic() >= next_date:
            plain, json_head, html_head, notfound = _responses()
            next_date = monotonic() + 1.0
        for fd, ev in events:
            if fd == lfd:
                while True:
                    try:
                        sock, _ = accept()
                    except (BlockingIOError, InterruptedError):
                        break
                    except OSError:
                        break
                    sock.setblocking(False)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    cfd = sock.fileno()
                    conns[cfd] = [sock, sock.recv_into, sock.send, None, None]
                    register(cfd, EPOLLIN)
                continue

            c = conns.get(fd)
            if c is None:
                continue

            if c[4] is not None:  # queued output: flush before reading anything else
                try:
                    sent = c[2](c[4])
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    close(fd, c)
                    continue
                if sent < len(c[4]):
                    c[4] = c[4][sent:]
                    continue
                c[4] = None
                modify(fd, EPOLLIN)
                continue

            head = c[3]
            try:
                if head is None:
                    n = c[1](buf)
                    if n == 0:
                        close(fd, c)
                        continue
                else:  # rare: a request was split across reads; read right after its first part
                    keep = len(head)
                    if keep > HALF:
                        close(fd, c)  # request headers larger than half the buffer
                        continue
                    mv[:keep] = head
                    n = c[1](mv[keep:])
                    if n == 0:
                        close(fd, c)
                        continue
                    n += keep
                    c[3] = None
            except (BlockingIOError, InterruptedError):
                continue
            except OSError:
                close(fd, c)
                continue

            out = []
            append = out.append
            pos = 0
            while pos < n:
                if FAST_PATH and last_kind in FAST_KINDS and startswith(last_req, pos, n):
                    pos += last_len
                    kind = last_kind
                    target = None
                else:
                    end = find(b"\r\n\r\n", pos, n)
                    if end < 0:
                        break
                    sp = find(b" ", pos + 4, end)
                    target = bytes(mv[pos + 4:sp])
                    if target == b"/plaintext":
                        kind = PLAIN
                    elif target == b"/json":
                        kind = JSON_
                    elif target == b"/db":
                        kind = DB
                    elif target.startswith(b"/queries"):
                        kind = QUERIES
                    elif target == b"/fortunes":
                        kind = FORTUNES
                    elif target.startswith(b"/updates"):
                        kind = UPDATES
                    else:
                        kind = NOTFOUND
                    end += 4
                    if kind in FAST_KINDS:
                        last_req, last_len, last_kind = bytes(mv[pos:end]), end - pos, kind
                    else:
                        last_kind = NOTFOUND
                    pos = end
                if kind == PLAIN:
                    append(plain)
                elif kind == JSON_:
                    body = _dumps({"message": "Hello, World!"}).encode()
                    append(json_head + _LEN[len(body)] + body)
                elif kind == DB:
                    body = corpo_db(_rand(1, 10001))
                    append(json_head + _LEN[len(body)] + body)
                elif kind == QUERIES:
                    body = corpo_queries(_q_param(target))
                    append(json_head + _LEN[len(body)] + body)
                elif kind == UPDATES:
                    body = corpo_updates(_q_param(target))
                    append(json_head + _LEN[len(body)] + body)
                elif kind == FORTUNES:
                    body = _fortunes_html(db.fortunes())
                    append(html_head + _cl(len(body)) + body)
                else:
                    append(notfound)
            if pos < n:
                c[3] = bytes(mv[pos:n])
            if not out:
                continue

            data = out[0] if len(out) == 1 else b"".join(out)
            try:
                sent = c[2](data)
            except (BlockingIOError, InterruptedError):
                sent = 0
            except OSError:
                close(fd, c)
                continue
            if sent < len(data):
                c[4] = data[sent:]
                modify(fd, EPOLLOUT)


def main():
    cpus = sorted(os.sched_getaffinity(0))
    pin = os.environ.get("PIN_WORKERS", "1") == "1" and WORKERS == len(cpus)
    socks = [_listen_socket() for _ in range(WORKERS)]
    children = []
    for i, sock in enumerate(socks):
        pid = os.fork()
        if pid == 0:
            for other in socks:
                if other is not sock:
                    other.close()
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            try:
                _worker(sock, cpus[i] if pin else None)
            finally:
                os._exit(0)
        children.append(pid)
    print(f"python-platform-epoll: {WORKERS} workers on :{PORT} (cpus {cpus}, pinned={pin}, "
          f"fast path={FAST_PATH}), Python {sys.version.split()[0]}", flush=True)

    def stop(*_):
        for pid in children:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    for _ in children:
        try:
            os.wait()
        except ChildProcessError:
            break


if __name__ == "__main__":
    main()
