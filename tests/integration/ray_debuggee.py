"""A stand-in for a Ray worker that hits `breakpoint()`.

This mimics the exact sequence Ray uses in ``python/ray/util/debugpy.py``
(``set_trace``): start a debugpy listener on an ephemeral port, wait for a
debugger client, then suspend the calling frame with ``pydevd.settrace``.
"""

import builtins
import sys

import debugpy

HOST = "127.0.0.1"


def ray_set_trace():
    debugpy.wait_for_client()
    # Ray imports pydevd lazily here, once debugpy has put its vendored
    # copy on sys.path.
    import pydevd

    pydevd.settrace(stop_at_frame=sys._getframe().f_back)


sys.breakpointhook = ray_set_trace
builtins.breakpoint = ray_set_trace


def f(x):
    breakpoint()
    return x * 2


if __name__ == "__main__":
    _, port = debugpy.listen((HOST, 0))
    print(f"PORT={port}", flush=True)
    print(f"RESULT={f(21)}", flush=True)
    print("DONE", flush=True)
