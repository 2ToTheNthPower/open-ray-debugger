"""Ray Job entrypoint: `ray job submit --working-dir workdir_app -- python job_entry.py`."""

import ray

import app_task

ray.init()
print(f"RESULT={ray.get(app_task.double.remote(21))}", flush=True)
