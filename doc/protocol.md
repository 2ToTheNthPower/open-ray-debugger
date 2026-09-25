# The Ray debugger protocol, as used by this plugin

Everything in this document is implemented in the open source
[Ray repository](https://github.com/ray-project/ray) and the open source
[debugpy](https://github.com/microsoft/debugpy) project. There is no Anyscale
specific protocol involved; the closed source VS Code extension is only one
possible frontend for it.

## 1. The debuggee side (inside the Ray cluster)

When a task or actor calls `breakpoint()`, Ray routes it to the distributed
debugger:

* `python/ray/_private/worker.py` sets `PYTHONBREAKPOINT=ray.util.rpdb.set_trace`
  for every worker process.
* `python/ray/util/rpdb.py:set_trace` dispatches on the `RAY_DEBUG` environment
  variable:
  * `RAY_DEBUG=1` (default) → `python/ray/util/debugpy.py:set_trace`
  * `RAY_DEBUG=legacy` → the legacy PDB-over-Telnet protocol (not supported by
    this plugin)

`python/ray/util/debugpy.py` then:

1. Calls `debugpy.listen((node_ip_address, 0))` on first use. `debugpy.listen`
   spawns a `debugpy.adapter` process **on the worker node** which accepts DAP
   client connections on the given port, and connects pydevd (inside the worker)
   to that adapter.
2. Stores the returned port in the cluster's worker state via
   `WorkerState.set_debugger_port` → `ray._private.state.update_worker_debugger_port`.
3. Enters `worker_paused_by_debugger()`, which increments
   `WorkerState.num_paused_threads`, and blocks in `debugpy.wait_for_client()`.
4. Once a client is attached, it suspends the task frame with
   `pydevd.settrace(stop_at_frame=...)` (or stops on the unhandled exception for
   post-mortem debugging when `RAY_DEBUG_POST_MORTEM=1`).

Because `debugpy.listen()` runs the adapter on the worker, the port the worker
publishes is a **DAP server**. A DAP client (nvim-dap) can connect to it
directly — no local adapter process is needed.

## 2. Discovery through the dashboard State API

The Ray dashboard (default port 8265) serves the State REST API. The relevant
endpoints are implemented in
`python/ray/dashboard/modules/state/state_head.py`:

| Endpoint | Purpose |
| --- | --- |
| `GET /api/v0/workers?detail=1` | find workers with an open debugger port and paused threads |
| `GET /api/v0/tasks?detail=1&filter_keys=worker_id&filter_predicates=%3D&filter_values=<id>` | find the task a paused worker is running |

Relevant fields (`python/ray/util/state/common.py`):

* `WorkerState.debugger_port` (detail column) — DAP port of the worker.
* `WorkerState.num_paused_threads` (detail column) — > 0 while waiting for a
  debugger.
* `WorkerState.ip`, `WorkerState.pid`, `WorkerState.is_alive`.
* `TaskState.worker_id`, `TaskState.state`, `TaskState.func_or_class_name`,
  `TaskState.name`, `TaskState.actor_id`, `TaskState.error_type`.
* `TaskState.is_debugger_paused` (detail column) — set by some Ray versions and
  used as a preference when several tasks share a worker.

The response envelope is:

```json
{
  "result": true,
  "msg": "",
  "data": {
    "result": {
      "result": [ ...rows... ],
      "total": 3,
      "num_after_truncation": 3,
      "num_filtered": 3
    }
  }
}
```

The rows live in `data.result.result`; `data.result` carries the
`ListApiResponse` metadata.  (Some Ray versions and simplified deployments
flatten this to `data.result` = rows, so the plugin accepts both shapes.)

Example:

```bash
curl -s 'http://127.0.0.1:8265/api/v0/workers?detail=1&limit=10000' |
  python3 -c 'import json,sys; [print(w["worker_id"], w["ip"], w["debugger_port"], w["num_paused_threads"]) for w in json.load(sys.stdin)["data"]["result"]["result"] if w["num_paused_threads"]]'
```

Version notes:

* `num_paused_threads` was added to worker state after the debugger itself; on
  older clusters the plugin falls back to "has a non-zero `debugger_port`".
* `debugger_port` and `num_paused_threads` are *detail* columns, so requests
  must pass `detail=1`.

## 3. Attaching

The plugin registers an nvim-dap adapter of type `server`:

```lua
dap.adapters.ray = function(cb, config)
  cb({
    type = "server",
    id = "python",              -- adapterID sent in `initialize`
    host = config.host,         -- worker ip from the State API
    port = config.port,         -- debugger_port from the State API
    options = { source_filetype = "python" },
  })
end
```

and runs a standard attach configuration:

```lua
{
  type = "ray",
  request = "attach",
  host = "<worker ip>",
  port = <debugger_port>,
  justMyCode = false,                    -- optional
  pathMappings = { { localRoot = ..., remoteRoot = ... } },  -- optional
}
```

nvim-dap then performs the usual DAP handshake: `initialize` → `attach` →
`initialized` event → `setBreakpoints`/`setExceptionBreakpoints` →
`configurationDone` → `stopped`/`continued`/... events. debugpy answers with
the stopped frame, scopes, variables and supports live breakpoints, stepping,
and expression evaluation like any local Python debug session.

One Ray-specific detail: Ray's `breakpoint()` support suspends the frame of
its own `set_trace` helper (`pydevd.settrace(stop_at_frame=...)` in
`ray/util/debugpy.py`), so the first stop of a session can land in
`ray/util/rpdb.py` rather than in the task. The plugin detects stops whose
leading frames are Ray/debugpy plumbing and selects the first user frame
automatically (`attach.skip_internal_frames`).

## 4. Ray Jobs and `working_dir`

Tasks with `runtime_env={"working_dir": ...}` (and every Ray Job) run from an
unpacked copy: `<ray temp dir>/session_*/runtime_resources/working_dir_files/_ray_pkg_<hash>/`.
Ray sets the worker's cwd to that directory, and the task's runtime env is
visible in the State API (`TaskState.runtime_env_info.serialized_runtime_env`,
a JSON string with `"working_dir": "gcs://_ray_pkg_<hash>.zip"`).

debugpy resolves `remoteRoot = "."` in `pathMappings` to the debuggee's cwd
(`pydevd_process_net_command_json.py:_resolve_remote_root`), so for such tasks
the plugin adds `{ localRoot = <local project>, remoteRoot = "." }`. That maps
stack frames to local files and local breakpoints to the cluster copy.

## 5. Post-mortem and debugpy >= 1.8.6

In post-mortem mode Ray calls `pydevd.stop_on_unhandled_exception` from
`ray/util/debugpy.py:_debugpy_excepthook`, which runs after the task frame has
unwound (the call comes from Cython in `_raylet.pyx`). debugpy 1.8.0–1.8.5
report the traceback frames. From debugpy 1.8.6 on (still the case in 1.8.22),
the reported stack is the *current* Python stack (`contextlib` helper, Ray's
excepthook, worker loop), and the `exceptionInfo` request fails with
`AttributeError: 'NoneType' object has no attribute '__qualname__'`. The same
happens with a plain-Python reproduction
(`tests/integration/ray_post_mortem_debuggee.py`), so it's a debugpy regression
rather than a Ray-specific one.

The plugin works around it:

* In a `before.stackTrace` listener, if the stack contains
  `_debugpy_excepthook`, it clears `supportsExceptionInfoRequest` for that
  session, so nvim-dap doesn't show the internal error.
* On the `exception` stop it evaluates an expression in the hook frame, where
  `error = sys.exc_info()`, that returns the traceback frames (file, line,
  function, `reprlib` reprs of the locals) and the worker cwd as JSON. debugpy
  returns the value as a Python `repr`, which the plugin unescapes.
* It puts the traceback in the quickfix list (applying the same path
  mappings), jumps to the innermost user frame, prints the locals in the
  REPL, and selects the hook frame so REPL expressions can use `error`.

## References

* Ray debugger user guide: <https://docs.ray.io/en/latest/ray-observability/ray-distributed-debugger.html>
* Ray source: `python/ray/util/debugpy.py`, `python/ray/util/rpdb.py`,
  `python/ray/_private/worker.py`, `python/ray/dashboard/modules/state/state_head.py`,
  `python/ray/util/state/common.py`
* Debug Adapter Protocol: <https://microsoft.github.io/debug-adapter-protocol/>
* debugpy: <https://github.com/microsoft/debugpy>
