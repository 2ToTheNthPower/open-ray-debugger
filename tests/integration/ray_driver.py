"""A Ray app with a task that pauses on `breakpoint()`.

Used by tests/integration/real_ray_cluster.sh to validate ray-debugger.nvim
against an actual Ray cluster (dashboard State API + worker debugger ports).
"""

import ray

ray.init(address="auto")


@ray.remote
def square(x):
    y = x * x
    breakpoint()
    return y


if __name__ == "__main__":
    result = ray.get(square.remote(21))
    print(f"RESULT={result}", flush=True)
