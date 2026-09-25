"""Two Ray tasks paused on breakpoint() at the same time.

Use this to check that the `:RayDebug` picker (<leader>dR) tells the paused
tasks apart well enough to attach to the one you want.

Setup:

    pip install "ray[default]" debugpy

Usage:

    python examples/ray_two_tasks_demo.py        # two different functions
    python examples/ray_two_tasks_demo.py same   # one function, two named tasks

Each task prints who it is before pausing, for example:

    (preprocess pid=4242) preprocess: shard=a task_id=16310a0f... pid=4242

Run `:RayDebug`, pick an entry, and compare the `whoami` local in the
Variables pane with the printed lines to confirm you attached to that task.
Continue (or disconnect) to let each task finish.
"""

import os
import sys

import ray

SAME_FUNCTION = len(sys.argv) > 1 and sys.argv[1] == "same"

ray.init()


def describe(kind, **args):
    context = ray.get_runtime_context()
    whoami = {
        "kind": kind,
        **args,
        "task_id": context.get_task_id(),
        "pid": os.getpid(),
    }
    details = " ".join(f"{key}={value}" for key, value in whoami.items() if key != "kind")
    print(f"{kind}: {details}", flush=True)
    return whoami


@ray.remote
def preprocess(shard):
    whoami = describe("preprocess", shard=shard)
    rows = [f"{shard}-{i}" for i in range(3)]
    breakpoint()  # <-- task 1 pauses here
    return {"whoami": whoami, "rows": rows}


@ray.remote
def train(model):
    whoami = describe("train", model=model)
    loss = 0.42
    breakpoint()  # <-- task 2 pauses here
    return {"whoami": whoami, "loss": loss}


@ray.remote
def evaluate(split):
    whoami = describe("evaluate", split=split)
    accuracy = 0.9 if split == "validation" else 0.8
    breakpoint()  # <-- both tasks pause here
    return {"whoami": whoami, "accuracy": accuracy}


if __name__ == "__main__":
    if SAME_FUNCTION:
        # The hard case: same function, only the arguments and task names differ.
        refs = [
            evaluate.options(name="evaluate-validation").remote("validation"),
            evaluate.options(name="evaluate-test").remote("test"),
        ]
    else:
        refs = [preprocess.remote("a"), train.remote("resnet")]

    print("Two tasks will pause on breakpoint(); attach with :RayDebug.", flush=True)
    for result in ray.get(refs):
        print(result)
