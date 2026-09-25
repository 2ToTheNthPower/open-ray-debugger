"""A stand-in for a Ray worker in post-mortem mode (RAY_DEBUG_POST_MORTEM=1).

Mimics ``python/ray/util/debugpy.py``: when a task raises, the worker waits
for a debugger client and then hands the exception to
``pydevd.stop_on_unhandled_exception``. pydevd only stops if the client has
enabled "uncaught" exception breakpoints.
"""

import sys
import threading

import debugpy

HOST = "127.0.0.1"


def _debugpy_excepthook():
    debugpy.wait_for_client()
    import pydevd

    py_db = pydevd.get_global_debugger()
    thread = threading.current_thread()
    additional_info = py_db.set_additional_thread_info(thread)
    additional_info.is_tracing += 1
    try:
        error = sys.exc_info()
        py_db.stop_on_unhandled_exception(py_db, thread, additional_info, error)
    finally:
        additional_info.is_tracing -= 1


def explode(x):
    values = [x, x + 1]
    raise ValueError(f"boom: {values}")


if __name__ == "__main__":
    _, port = debugpy.listen((HOST, 0))
    print(f"PORT={port}", flush=True)
    try:
        explode(1)
    except ValueError:
        _debugpy_excepthook()
    print("DONE", flush=True)
