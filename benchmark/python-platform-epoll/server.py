"""CPython "platform" HTTP server with its own epoll loop (plaintext and json tests).

Same idea as dotnet-platform's EventLoop/: no asyncio, no uvloop, no HTTP library. Standard
library only (select.epoll, socket, json), so there is nothing to install.

- One process per CPU in the affinity mask, each with its own SO_REUSEPORT listening socket and
  its own epoll instance. The parent creates the sockets before forking and keeps them open, so
  the pid run-suite.sh starts is the one holding the listener.
- One shared receive buffer per process (recv_into, no allocation per read). A partial request
  left at the end of a read is copied to the connection and joined with the next read.
- Pipelining: every complete request in a read is answered with a single send().
- Request fast path: the bytes of the last parsed request are kept, and the next request is first
  compared against them (one memcmp). A different request falls back to the parser, so this is
  correct for any input, but it is an optimization aimed at benchmark-style repeated requests.
- /json serializes per request (a TechEmpower rule) with the stdlib json module.
- Backpressure: on a short send() the rest is queued and the connection is not read again
  until the queue is flushed.

Assumed limitations (same as the platform entries): HTTP/1.1 only, GET without a body, no TLS.
"""
import gc
import json
import os
import select
import signal
import socket
import sys
from email.utils import formatdate
from time import monotonic

PORT = int(os.environ.get("PORT", "8080"))
WORKERS = int(os.environ.get("WORKERS", "0")) or len(os.sched_getaffinity(0))
FAST_PATH = os.environ.get("FAST_PATH", "1") == "1"

_dumps = json.JSONEncoder(separators=(",", ":")).encode
_LEN = tuple(str(i).encode() + b"\r\n\r\n" for i in range(1024))  # Content-Length value + end of headers

EPOLLIN, EPOLLOUT = select.EPOLLIN, select.EPOLLOUT
PLAIN, JSON, NOTFOUND = 0, 1, 2


def _responses():
    date = formatdate(usegmt=True).encode()
    common = b"Server: py\r\nDate: " + date + b"\r\n"
    plain = (b"HTTP/1.1 200 OK\r\n" + common +
             b"Content-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!")
    json_head = b"HTTP/1.1 200 OK\r\n" + common + b"Content-Type: application/json\r\nContent-Length: "
    notfound = b"HTTP/1.1 404 Not Found\r\n" + common + b"Content-Length: 0\r\n\r\n"
    return plain, json_head, notfound


def _listen_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("0.0.0.0", PORT))
    s.listen(4096)
    s.setblocking(False)
    return s


def _worker(lsock, cpu):
    if cpu is not None:
        os.sched_setaffinity(0, {cpu})
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
    last_req, last_len, last_kind = b"\x00", 1, NOTFOUND  # never matches a real request

    plain, json_head, notfound = _responses()
    next_date = monotonic() + 1.0

    def close(fd, c):
        try:
            unregister(fd)
        except OSError:
            pass
        c[0].close()
        del conns[fd]

    gc.collect()
    gc.freeze()  # startup objects never get rescanned by the cyclic GC

    while True:
        events = poll(1.0)
        if monotonic() >= next_date:
            plain, json_head, notfound = _responses()
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
                if FAST_PATH and startswith(last_req, pos, n):
                    pos += last_len
                    kind = last_kind
                else:
                    end = find(b"\r\n\r\n", pos, n)
                    if end < 0:
                        break
                    target = find(b" ", pos, end) + 1  # request line: "GET /path HTTP/1.1"
                    if startswith(b"/plaintext ", target):
                        kind = PLAIN
                    elif startswith(b"/json ", target):
                        kind = JSON
                    else:
                        kind = NOTFOUND
                    end += 4
                    last_req, last_len, last_kind = bytes(mv[pos:end]), end - pos, kind
                    pos = end
                if kind == PLAIN:
                    append(plain)
                elif kind == JSON:
                    body = _dumps({"message": "Hello, World!"}).encode()
                    append(json_head + _LEN[len(body)] + body)
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
