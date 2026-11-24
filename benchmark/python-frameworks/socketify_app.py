"""socketify.py: HTTP server is uWebSockets (C++). Python runs only the two handlers. JSON by orjson (Rust)."""
import orjson
from socketify import App

from common import PORT, fork_per_cpu


def plaintext(res, req):
    res.send(b"Hello, World!")


def json_handler(res, req):
    res.send(orjson.dumps({"message": "Hello, World!"}), b"application/json")


def serve():
    app = App()
    app.get("/plaintext", plaintext)
    app.get("/json", json_handler)
    app.listen(PORT, lambda config: None)
    app.run()


if __name__ == "__main__":
    fork_per_cpu(serve)
