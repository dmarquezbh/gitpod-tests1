"""python-platform with the hot path compiled by Cython (see handler.pyx, build with build.sh).

Same process model as python-platform/server.py: one process per CPU with SO_REUSEPORT, uvloop,
Date refreshed every second. JSON_LIB=orjson swaps the stdlib json module for orjson (Rust).
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

import handler

PORT = int(os.environ.get("PORT", "8080"))
WORKERS = int(os.environ.get("WORKERS", "0")) or len(os.sched_getaffinity(0))
FAST_PATH = os.environ.get("FAST_PATH", "1") == "1"
JSON_LIB = os.environ.get("JSON_LIB", "json")

if JSON_LIB == "orjson":
    import orjson
    handler.configure(orjson.dumps, False, FAST_PATH)
else:
    handler.configure(json.JSONEncoder(separators=(",", ":")).encode, True, FAST_PATH)


def _refresh_date(loop=None):
    date = formatdate(usegmt=True).encode()
    common = b"Server: py\r\nDate: " + date + b"\r\n"
    handler.set_responses(
        b"HTTP/1.1 200 OK\r\n" + common + b"Content-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!",
        b"HTTP/1.1 200 OK\r\n" + common + b"Content-Type: application/json\r\nContent-Length: ",
        b"HTTP/1.1 404 Not Found\r\n" + common + b"Content-Length: 0\r\n\r\n")
    if loop is not None:
        loop.call_later(1.0, _refresh_date, loop)


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
    loop.run_until_complete(loop.create_server(handler.HttpProtocol, sock=sock, backlog=4096))
    gc.collect()
    gc.freeze()
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
    print(f"python-platform-cython: {WORKERS} workers on :{PORT} (cpus {cpus}, pinned={pin}, json={JSON_LIB}, "
          f"fast path={FAST_PATH}), Python {sys.version.split()[0]}, uvloop {uvloop.__version__}", flush=True)

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
