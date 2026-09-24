"""Minimal Ray app for trying out ray-debugger.nvim.

Setup:

    pip install "ray[default]" debugpy

Usage:

    python examples/ray_breakpoint_demo.py             # breakpoint() demo
    python examples/ray_breakpoint_demo.py post-mortem  # frozen exception demo

Then run `:RayDebug` in Neovim and pick the paused task.
"""

import sys

import ray

POST_MORTEM = len(sys.argv) > 1 and sys.argv[1] == "post-mortem"

ray.init(
    runtime_env={
        "env_vars": {"RAY_DEBUG_POST_MORTEM": "1"} if POST_MORTEM else {},
    }
)


@ray.remote
def square(x):
    y = x * x
    breakpoint()  # <-- ray-debugger.nvim attaches here
    return y


@ray.remote
def explode():
    values = [1, 2, 3]
    raise ValueError(f"frozen for post-mortem debugging: values={values!r}")
    return values


if __name__ == "__main__":
    if POST_MORTEM:
        print("A task will freeze on a ValueError; attach with :RayDebug.")
        ray.get(explode.remote())
    else:
        print("Tasks will pause on breakpoint(); attach with :RayDebug.")
        print(ray.get([square.remote(i) for i in range(2)]))
