"""FastPySGI: HTTP server is C on libuv. Python runs a WSGI callable. JSON by orjson (Rust)."""
import fastpysgi
import orjson

from common import PORT, fork_per_cpu

PLAIN_HEADERS = [("Content-Type", "text/plain"), ("Content-Length", "13")]
JSON_HEADERS = [("Content-Type", "application/json")]


def app(environ, start_response):
    path = environ["PATH_INFO"]
    if path == "/plaintext":
        start_response("200 OK", PLAIN_HEADERS)
        return [b"Hello, World!"]
    if path == "/json":
        start_response("200 OK", JSON_HEADERS)
        return [orjson.dumps({"message": "Hello, World!"})]
    start_response("404 Not Found", [("Content-Length", "0")])
    return [b""]


def serve():
    fastpysgi.server.init(app, "0.0.0.0", PORT, loglevel=0)
    fastpysgi.server.run()


if __name__ == "__main__":
    fork_per_cpu(serve)
