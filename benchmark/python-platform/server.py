"""CPython "platform" HTTP server for the TechEmpower plaintext and json tests.

The CPython equivalent of dotnet-platform/: no framework and no HTTP library, just
asyncio.Protocol on uvloop with a hand-written request-line parser.

- One process per CPU in the affinity mask (taskset), each with its own SO_REUSEPORT
  listening socket. The kernel spreads connections across them, so there is no GIL contention.
- The parent creates every listening socket before forking and keeps them open, so the pid
  run-suite.sh starts is the one holding the listener (run-suite.sh checks this).
- Pipelining: every complete request in a read is answered, then a single transport.write.
- Response headers are prebuilt as bytes. Date is refreshed by a 1 s timer.
- /json serializes per request (a TechEmpower rule) with the stdlib json module.

Assumed limitations (same as the platform entries): HTTP/1.1 only, GET without a body, no TLS.
"""
import gc
import json
import os
import signal
import socket
import sys
from email.utils import formatdate

import asyncio
import uvloop

PORT = int(os.environ.get("PORT", "8080"))
WORKERS = int(os.environ.get("WORKERS", "0")) or len(os.sched_getaffinity(0))

FAST_PATH = os.environ.get("FAST_PATH", "1") == "1"
# Request fast path: bytes of the last parsed request and its route (per worker process). A request
# that differs falls back to the parser, so this is correct for any input, but it is an
# optimization aimed at benchmark-style repeated requests. FAST_PATH=0 turns it off.
_last_req, _last_len, _last_kind = b"\x00", 1, 2

_dumps = json.JSONEncoder(separators=(",", ":")).encode
# JSON_LIB=orjson swaps the stdlib json module for orjson (a Rust library): a separate, labelled variant
_ORJSON = os.environ.get("JSON_LIB", "json") == "orjson"
if _ORJSON:
    from orjson import dumps as _orjson_dumps
_PLAIN_BODY = b"Hello, World!"

# Rebuilt every second by _refresh_date (a per-worker global: no locking needed)
_plain_resp = b""
_json_head = b""
_notfound_resp = b""


def _refresh_date(loop=None):
    global _plain_resp, _json_head, _notfound_resp
    date = formatdate(usegmt=True).encode()
    common = b"Server: py\r\nDate: " + date + b"\r\n"
    _plain_resp = (b"HTTP/1.1 200 OK\r\n" + common +
                   b"Content-Type: text/plain\r\nContent-Length: 13\r\n\r\n" + _PLAIN_BODY)
    _json_head = b"HTTP/1.1 200 OK\r\n" + common + b"Content-Type: application/json\r\nContent-Length: "
    _notfound_resp = b"HTTP/1.1 404 Not Found\r\n" + common + b"Content-Length: 0\r\n\r\n"
    if loop is not None:
        loop.call_later(1.0, _refresh_date, loop)


class HttpProtocol(asyncio.Protocol):
    __slots__ = ("transport", "buf")

    def __init__(self):
        self.transport = None
        self.buf = b""

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        buf = self.buf + data if self.buf else data
        find = buf.find
        startswith = buf.startswith
        global _last_req, _last_len, _last_kind
        out = []
        append = out.append
        pos = 0
        n = len(buf)
        while pos < n:
            if FAST_PATH and startswith(_last_req, pos):
                # same bytes as the last parsed request: reuse its route (one memcmp, no parsing)
                pos += _last_len
                kind = _last_kind
            else:
                end = find(b"\r\n\r\n", pos)
                if end < 0:
                    break
                # request line: "GET /path HTTP/1.1"
                target = find(b" ", pos, end) + 1
                if startswith(b"/plaintext ", target):
                    kind = 0
                elif startswith(b"/json ", target):
                    kind = 1
                else:
                    kind = 2
                end += 4
                _last_req, _last_len, _last_kind = buf[pos:end], end - pos, kind
                pos = end
            if kind == 0:
                append(_plain_resp)
            elif kind == 1:
                if _ORJSON:
                    body = _orjson_dumps({"message": "Hello, World!"})
                else:
                    body = _dumps({"message": "Hello, World!"}).encode()
                append(_json_head + str(len(body)).encode() + b"\r\n\r\n" + body)
            else:
                append(_notfound_resp)
        self.buf = buf[pos:] if pos < n else b""
        if out:
            self.transport.write(out[0] if len(out) == 1 else b"".join(out))

    def connection_lost(self, exc):
        self.transport = None


def _listen_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.bind(("0.0.0.0", PORT))
    s.listen(4096)
    s.setblocking(False)
    return s


def _worker(sock, cpu):
    if cpu is not None:
        os.sched_setaffinity(0, {cpu})
    loop = uvloop.new_event_loop()
    asyncio.set_event_loop(loop)
    _refresh_date(loop)
    loop.run_until_complete(loop.create_server(HttpProtocol, sock=sock, backlog=4096))
    gc.collect()
    gc.freeze()  # startup objects never get rescanned by the cyclic GC
    loop.run_forever()


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
    print(f"python-platform: {WORKERS} workers on :{PORT} (cpus {cpus}, pinned={pin}), "
          f"Python {sys.version.split()[0]}, uvloop {uvloop.__version__}", flush=True)

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
