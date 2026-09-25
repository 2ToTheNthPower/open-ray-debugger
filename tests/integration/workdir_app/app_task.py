"""Task module shipped to the cluster through `runtime_env={"working_dir": ...}`."""

import ray


@ray.remote
def double(x):
    y = x * 2
    breakpoint()
    z = y + 0
    return z  # a local nvim-dap breakpoint is set here by the Ray Job test
