"""Granian: HTTP server is Rust (hyper/tokio). Python runs an RSGI callable. JSON by orjson (Rust).

Uses Granian's embedded server, one per process, instead of the `granian` CLI: with the CLI the
listening sockets belong to the worker processes, and run-suite.sh requires the pid it starts to
hold the listener.
"""
import asyncio

import orjson
import uvloop
from granian.constants import HTTPModes
from granian.http import HTTP1Settings
from granian.server.embed import Server

from common import PORT, fork_per_cpu

PLAIN_HEADERS = [("content-type", "text/plain")]
JSON_HEADERS = [("content-type", "application/json")]


async def main(scope, proto):
    path = scope.path
    if path == "/plaintext":
        proto.response_bytes(200, PLAIN_HEADERS, b"Hello, World!")
    elif path == "/json":
        proto.response_bytes(200, JSON_HEADERS, orjson.dumps({"message": "Hello, World!"}))
    else:
        proto.response_empty(404, [])


def serve():
    async def run():
        server = Server(main, address="0.0.0.0", port=PORT, http=HTTPModes.http1, websockets=False,
                        backlog=4096, http1_settings=HTTP1Settings(pipeline_flush=True), log_enabled=False)
        await server.serve()
    uvloop.run(run())


if __name__ == "__main__":
    fork_per_cpu(serve)
