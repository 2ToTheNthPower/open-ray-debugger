"""Ray app scenarios used by tests/integration/real_ray_cluster.sh.

    python ray_driver.py breakpoint   # task pauses on breakpoint()
    python ray_driver.py actor        # actor method pauses on breakpoint()
    python ray_driver.py post-mortem  # task raises; frozen for post-mortem debugging
    python ray_driver.py working-dir  # task shipped via runtime_env working_dir
"""

import os
import sys

import ray

SCENARIO = sys.argv[1] if len(sys.argv) > 1 else "breakpoint"
HERE = os.path.dirname(os.path.abspath(__file__))
WORKDIR_APP = os.path.join(HERE, "workdir_app")

runtime_env = {}
if SCENARIO == "post-mortem":
    runtime_env = {"env_vars": {"RAY_DEBUG_POST_MORTEM": "1"}}
elif SCENARIO == "working-dir":
    runtime_env = {"working_dir": WORKDIR_APP}
    sys.path.insert(0, WORKDIR_APP)

ray.init(address="auto", runtime_env=runtime_env)


@ray.remote
def square(x):
    y = x * x
    breakpoint()
    return y


@ray.remote
class Counter:
    def __init__(self):
        self.value = 20

    def bump(self, amount):
        self.value += amount
        breakpoint()
        return self.value


@ray.remote(max_retries=0)
def explode(x):
    values = [x, x + 1]
    raise ValueError(f"boom: {values}")


if __name__ == "__main__":
    if SCENARIO == "breakpoint":
        print(f"RESULT={ray.get(square.remote(21))}", flush=True)
    elif SCENARIO == "actor":
        counter = Counter.remote()
        print(f"RESULT={ray.get(counter.bump.remote(1))}", flush=True)
    elif SCENARIO == "post-mortem":
        try:
            ray.get(explode.remote(1))
        except ValueError as exc:
            print(f"RESULT=raised {type(exc).__name__}", flush=True)
    elif SCENARIO == "working-dir":
        import app_task  # shipped to the cluster through the working_dir

        print(f"RESULT={ray.get(app_task.double.remote(21))}", flush=True)
    else:
        raise SystemExit(f"unknown scenario {SCENARIO!r}")
