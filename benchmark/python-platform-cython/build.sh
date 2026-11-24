#!/usr/bin/env bash
# Compiles handler.pyx in place. PYTHON: interpreter of a venv with cython and setuptools installed.
set -euo pipefail
cd "$(dirname "$0")"
PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}" CFLAGS="${CFLAGS:--O3 -march=native}" "$PYTHON" -m cython -3 handler.pyx -o handler.c
CC="${CC:-gcc}" CFLAGS="${CFLAGS:--O3 -march=native}" "$PYTHON" - <<'PY'
from setuptools import Extension, setup
setup(script_args=["build_ext", "--inplace", "-q"], ext_modules=[Extension("handler", ["handler.c"])])
PY
ls handler*.so
