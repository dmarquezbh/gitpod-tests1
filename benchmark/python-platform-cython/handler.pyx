# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
"""Hot path of python-platform compiled to C with Cython.

Grey zone, declared: this still runs inside CPython and still uses uvloop and the json module,
but the request parser and the response assembly are C code (memmem/memcmp/memcpy), not bytecode.
Same behaviour as python-platform/server.py, including the request fast path.
"""
from libc.string cimport memcmp, memcpy, memchr
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING, PyBytes_GET_SIZE

cdef extern from "string.h":
    void *memmem(const void *haystack, size_t hlen, const void *needle, size_t nlen) nogil

DEF OUT_CAP = 262144
DEF LAST_CAP = 2048

cdef char _out[OUT_CAP]          # per-process output buffer (one process per CPU, single thread)
cdef char _last[LAST_CAP]        # bytes of the last parsed request
cdef Py_ssize_t _last_len = 0
cdef int _last_kind = 2
cdef bint _fast = True
cdef bint _dumps_str = True      # stdlib json returns str; orjson returns bytes
cdef object _dumps = None
cdef bytes _plain = b""
cdef bytes _json_head = b""
cdef bytes _notfound = b""


def configure(dumps, bint dumps_returns_str, bint fast_path):
    global _dumps, _dumps_str, _fast
    _dumps = dumps
    _dumps_str = dumps_returns_str
    _fast = fast_path


def set_responses(bytes plain, bytes json_head, bytes notfound):
    """Called once per second with the responses carrying the current Date header."""
    global _plain, _json_head, _notfound
    _plain = plain
    _json_head = json_head
    _notfound = notfound


cdef class HttpProtocol:
    cdef object transport
    cdef bytes pending

    def connection_made(self, transport):
        self.transport = transport

    def connection_lost(self, exc):
        self.transport = None

    def data_received(self, bytes data):
        global _last_len, _last_kind
        cdef bytes buf = data if self.pending is None else self.pending + data
        cdef const char *p = PyBytes_AS_STRING(buf)
        cdef Py_ssize_t n = PyBytes_GET_SIZE(buf)
        cdef Py_ssize_t pos = 0, used = 0, rl, tlen, slen, blen, hlen, v
        cdef const char *e
        cdef const char *sp
        cdef const char *src
        cdef int kind, nd, i
        cdef char digits[24]
        cdef bytes body
        cdef object res
        cdef object write = self.transport.write

        while pos < n:
            if _fast and _last_len != 0 and n - pos >= _last_len and memcmp(p + pos, _last, _last_len) == 0:
                # same bytes as the last parsed request: reuse its route
                kind = _last_kind
                pos += _last_len
            else:
                e = <const char *>memmem(p + pos, n - pos, b"\r\n\r\n", 4)
                if e == NULL:
                    break
                rl = (e - (p + pos)) + 4
                kind = 2
                sp = <const char *>memchr(p + pos, 32, rl)  # request line: "GET /path HTTP/1.1"
                if sp != NULL:
                    tlen = (p + pos + rl) - (sp + 1)
                    if tlen >= 11 and memcmp(sp + 1, b"/plaintext ", 11) == 0:
                        kind = 0
                    elif tlen >= 6 and memcmp(sp + 1, b"/json ", 6) == 0:
                        kind = 1
                if rl <= LAST_CAP:
                    memcpy(_last, p + pos, rl)
                    _last_len = rl
                    _last_kind = kind
                pos += rl

            if kind == 1:
                # serialized per request (TechEmpower rule), by the configured JSON library
                res = _dumps({"message": "Hello, World!"})
                body = (<str>res).encode() if _dumps_str else <bytes>res
                blen = PyBytes_GET_SIZE(body)
                hlen = PyBytes_GET_SIZE(_json_head)
                if hlen + blen + 32 > OUT_CAP:
                    raise ValueError("json response larger than the output buffer")
                if used + hlen + blen + 32 > OUT_CAP:
                    write(PyBytes_FromStringAndSize(_out, used))
                    used = 0
                memcpy(_out + used, PyBytes_AS_STRING(_json_head), hlen)
                used += hlen
                nd = 0
                v = blen
                while True:
                    digits[nd] = <char>(48 + v % 10)
                    nd += 1
                    v //= 10
                    if v == 0:
                        break
                for i in range(nd - 1, -1, -1):
                    _out[used] = digits[i]
                    used += 1
                memcpy(_out + used, b"\r\n\r\n", 4)
                used += 4
                memcpy(_out + used, PyBytes_AS_STRING(body), blen)
                used += blen
            else:
                if kind == 0:
                    src = PyBytes_AS_STRING(_plain)
                    slen = PyBytes_GET_SIZE(_plain)
                else:
                    src = PyBytes_AS_STRING(_notfound)
                    slen = PyBytes_GET_SIZE(_notfound)
                if used + slen > OUT_CAP:
                    write(PyBytes_FromStringAndSize(_out, used))
                    used = 0
                memcpy(_out + used, src, slen)
                used += slen

        self.pending = buf[pos:] if pos < n else None
        if used:
            write(PyBytes_FromStringAndSize(_out, used))
