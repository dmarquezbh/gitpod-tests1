"""Shared process model for the servers whose HTTP layer is C, C++ or Rust.

run-suite.sh requires the pid it starts to hold a listening socket, so the parent forks one child
per extra CPU and then serves too. Children die with the parent (PR_SET_PDEATHSIG).
"""
import ctypes
import os
import signal

PORT = int(os.environ.get("PORT", "8080"))


def fork_per_cpu(serve):
    cpus = sorted(os.sched_getaffinity(0))
    for cpu in cpus[1:]:
        if os.fork() == 0:
            ctypes.CDLL(None).prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG
            os.sched_setaffinity(0, {cpu})
            serve()
            os._exit(0)
    os.sched_setaffinity(0, {cpus[0]})
    serve()
