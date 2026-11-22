"""TechEmpower-style benchmark server: Starlette + uvicorn + pg8000 (sync handlers, thread pool)."""
import os
import queue
import threading

import pg8000.dbapi
from starlette.applications import Starlette
from starlette.responses import HTMLResponse, JSONResponse, PlainTextResponse
from starlette.routing import Route

POOL_SIZE = int(os.environ.get("POOL_SIZE", "16"))
_conns: "queue.Queue" = queue.Queue()
_lock = threading.Lock()


def _connect():
    conn = pg8000.dbapi.connect(
        user="benchmarkdbuser",
        password="benchmarkdbpass",
        host="127.0.0.1",
        port=5432,
        database="hello_world",
    )
    conn.autocommit = True
    return conn


def _init_pool():
    for _ in range(POOL_SIZE):
        _conns.put(_connect())


_init_pool()


def _rand_id():
    import random
    return random.randint(1, 10000)


def _clamp(v):
    try:
        return max(1, min(500, int(v)))
    except (TypeError, ValueError):
        return 1


def _escape(s):
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#x27;")
        .replace("/", "&#x2F;")
    )


def _world(cur, wid):
    cur.execute("SELECT id, randomnumber FROM world WHERE id = %s", (wid,))
    return cur.fetchone()


def plaintext(request):
    return PlainTextResponse("Hello, World!")


def json_endpoint(request):
    return JSONResponse({"message": "Hello, World!"})


def db(request):
    conn = _conns.get()
    try:
        cur = conn.cursor()
        wid, rn = _world(cur, _rand_id())
        return JSONResponse({"id": wid, "randomNumber": rn})
    finally:
        _conns.put(conn)


def queries(request):
    n = _clamp(request.query_params.get("q") or request.query_params.get("queries"))
    conn = _conns.get()
    try:
        cur = conn.cursor()
        out = []
        for _ in range(n):
            wid, rn = _world(cur, _rand_id())
            out.append({"id": wid, "randomNumber": rn})
        return JSONResponse(out)
    finally:
        _conns.put(conn)


def updates(request):
    n = _clamp(request.query_params.get("q") or request.query_params.get("queries"))
    conn = _conns.get()
    try:
        cur = conn.cursor()
        rows = []
        for _ in range(n):
            wid, _rn = _world(cur, _rand_id())
            new_rn = _rand_id()
            cur.execute("UPDATE world SET randomnumber = %s WHERE id = %s", (new_rn, wid))
            rows.append({"id": wid, "randomNumber": new_rn})
        return JSONResponse(rows)
    finally:
        _conns.put(conn)


def fortunes(request):
    conn = _conns.get()
    try:
        cur = conn.cursor()
        cur.execute("SELECT id, message FROM fortune")
        rows = [(r[0], r[1]) for r in cur.fetchall()]
        rows.append((0, "Additional fortune added at request time."))
        rows.sort(key=lambda r: r[1])
        body = (
            "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>"
            "<tr><th>id</th><th>message</th></tr>"
        )
        for wid, msg in rows:
            body += f"<tr><td>{wid}</td><td>{_escape(msg)}</td></tr>"
        body += "</table></body></html>"
        return HTMLResponse(body)
    finally:
        _conns.put(conn)


app = Starlette(
    routes=[
        Route("/plaintext", plaintext),
        Route("/json", json_endpoint),
        Route("/db", db),
        Route("/queries", queries),
        Route("/updates", updates),
        Route("/fortunes", fortunes),
    ]
)
