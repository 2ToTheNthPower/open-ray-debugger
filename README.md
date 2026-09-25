# ray-debugger.nvim

An open source, Neovim-native replacement for the closed source **Anyscale Ray
Distributed Debugger** VS Code extension.

It attaches `nvim-dap` to Ray tasks and actors that are sitting on
`breakpoint()` (or on an unhandled exception, with post-mortem debugging), so
you can inspect variables, step through code, and evaluate expressions without
leaving Neovim.

* **No Node, no npm.** Pure Lua plugin; the only external program it runs is
  `curl` (which is open source and already on virtually every system).
* **No closed components.** The Ray debugger backend is part of the
  [Ray repository](https://github.com/ray-project/ray); this plugin speaks the
  same open protocols the VS Code extension speaks: the Ray dashboard State
  REST API and the Debug Adapter Protocol (DAP).
* **Works with LazyVim.** It plugs into `nvim-dap` and `vim.ui.select`, so your
  existing DAP keymaps, UI, and picker (telescope/fzf-lua/snacks) are used.

## How it works

Ray ships a distributed debugger in the open source Ray package
(`python/ray/util/debugpy.py`). When a task calls `breakpoint()`:

1. The worker starts a **debugpy** DAP server on an ephemeral port and records
   that port in the cluster state (`WorkerState.debugger_port`).
2. While it waits for a debugger, the worker reports
   `WorkerState.num_paused_threads > 0`.
3. A frontend polls the dashboard State API (`/api/v0/workers`) to find those
   workers and connects to `worker_ip:debugger_port` with DAP.

`ray-debugger.nvim` is that frontend:

```
                 Ray dashboard (State API)          Ray worker (node)
┌────────────┐   GET /api/v0/workers        ┌──────────────────────────────┐
│ Neovim     │ ───────────────────────────▶ │ dashboard                    │
│            │   GET /api/v0/tasks          └──────────────────────────────┘
│ ray-       │                                            ▲
│ debugger   │                                            │ debugger_port
│ .nvim      │   DAP over TCP (nvim-dap)                  │
│            │ ───────────────────────────────────────────┘
│            │        breakpoint() → debugpy server ⇄ task
└────────────┘
```

`debugpy.listen()` starts the DAP adapter inside the cluster, so attaching is a
plain DAP connection — no extra adapter process or IDE-specific glue is needed.

See [doc/protocol.md](doc/protocol.md) for the full protocol details,
including the exact Ray source files involved.

## Requirements

| Component | Why | Notes |
| --- | --- | --- |
| Neovim ≥ 0.10 | `vim.system` for async HTTP | a synchronous fallback exists for older versions |
| [nvim-dap](https://github.com/mfussenegger/nvim-dap) | DAP client | LazyVim: enable the `dap.core` extra |
| `curl` | dashboard REST requests | open source, preinstalled on most systems |
| Ray ≥ 2.9 on the cluster | distributed debugger backend | the default `RAY_DEBUG=1` mode, **not** `RAY_DEBUG=legacy` |
| `debugpy >= 1.8` on the cluster | DAP server | `pip install "ray[default]" debugpy` |

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim) (LazyVim):

```lua
-- lua/plugins/ray-debugger.lua
return {
  {
    "2ToTheNthPower/open-ray-debugger",
    -- or `dir = "~/path/to/open-ray-debugger"` for a local checkout
    dependencies = { "mfussenegger/nvim-dap" },
    -- Load on any :RayDebug* command, not only on the keys below.
    cmd = { "RayDebug", "RayDebugAttach", "RayDebugPostMortem", "RayDebugWatch", "RayDebugRefresh" },
    -- Chosen to not clash with LazyVim's DAP keys (<leader>dr is "Toggle REPL").
    keys = {
      { "<leader>dR", function() require("ray-debugger").pick() end, desc = "Ray: Attach to paused task" },
      { "<leader>dW", function() require("ray-debugger").watch() end, desc = "Ray: Toggle watch" },
    },
    opts = {
      dashboard_url = "http://127.0.0.1:8265",
    },
  },
}
```

Setting `keys` or `cmd` makes lazy.nvim lazy-load the plugin, so `:Lazy` lists
it under **Not Loaded** until you press one of the keys or run a `:RayDebug*`
command. That is expected. Keep the `cmd` list, or the commands won't exist
until you press a key. To load it at startup instead, add `lazy = false`. That's
cheap, because the Lua modules are only required when a command first runs.

If you have not enabled the LazyVim DAP extra yet:

```lua
{ import = "lazyvim.plugins.extras.dap.core" },
```

With Neovim's built-in package loader (no plugin manager required):

```bash
git clone https://github.com/2ToTheNthPower/open-ray-debugger \
  ~/.local/share/nvim/site/pack/plugins/start/open-ray-debugger
```

Then call `setup()` from your `init.lua`:

```lua
require("ray-debugger").setup({
  dashboard_url = "http://127.0.0.1:8265",
})
```

See [doc/ray-debugger.txt](doc/ray-debugger.txt) for `:help ray-debugger`.

## Usage

1. Install `debugpy` in the cluster environment (it is not part of `ray` by
   default):

   ```bash
   pip install "ray[default]" debugpy
   ```

2. Put a breakpoint in a task or actor method:

   ```python
   import ray

   ray.init()

   @ray.remote
   def compute(x):
       y = x * x
       breakpoint()   # <-- pauses the task and waits for you
       return y

   print(ray.get(compute.remote(6)))
   ```

   Ready-to-run versions live in [examples/](examples/):
   `ray_breakpoint_demo.py` (a single pause, plus a `post-mortem` mode) and
   `ray_two_tasks_demo.py` (two tasks paused at once, to try the picker).

3. Run the application. The task pauses and the worker starts waiting.

4. In Neovim:

   ```
   :RayDebug
   ```

   Pick the paused task from the list and the nvim-dap session starts, stopped
   in the task's frame. From there everything is normal nvim-dap: `:DapContinue`,
   `:DapStepOver`, `:DapToggleBreakpoint`, `:DapToggleRepl`, the nvim-dap-ui
   panels, etc.

5. Disconnect (`:DapDisconnect` or `require("dap").close()`) to let the task
   resume and join another paused task later. You can keep breakpoints set;
   attaching again to the same or a different task works the same way.

### Breakpoints (`<leader>db` and friends)

Breakpoints are plain nvim-dap breakpoints, so LazyVim's DAP keys work as
usual: `<leader>db` toggles a breakpoint, `<leader>dB` sets a conditional one,
`<leader>dc` continues, `<leader>dO`/`<leader>di`/`<leader>do` step.

* You can set them **before or after attaching**: breakpoints already set
  are sent to the worker when you attach, and new ones apply immediately.
* Once attached, they hit for any code the worker runs, including later tasks
  or actor calls on the same worker.
* For Ray Jobs / `working_dir` tasks, breakpoints set in your *local* files hit
  on the cluster's copy (see [Ray Jobs and `working_dir`](#ray-jobs-and-working_dir)).

One caveat, inherent to how Ray's debugger works: a worker only starts its
debug server when it reaches `breakpoint()` (or a post-mortem exception). A
`<leader>db` breakpoint alone can't pause a task that isn't already attached.
Use `breakpoint()` as the entry point, then use `<leader>db` breakpoints from
there.

### Post-mortem debugging

Set `RAY_DEBUG_POST_MORTEM=1` in the runtime environment and Ray freezes a task
that raises an unhandled exception instead of failing it, so you can inspect
the state at the point of the error:

```python
ray.init(runtime_env={"env_vars": {"RAY_DEBUG_POST_MORTEM": "1"}})

@ray.remote
def explode():
    x = 1
    raise ValueError("boom")  # the task freezes here for you to inspect
```

The frozen task shows up in `:RayDebug`; attach to it like any paused task.

> **debugpy ≥ 1.8.6 regression.** With debugpy 1.8.0–1.8.5 the debugger stops
> in the failing frame. Since debugpy 1.8.6, the way Ray hands the exception
> to debugpy produces the *current* stack (Ray's worker loop) instead of the
> traceback, and debugpy's `exceptionInfo` request fails, so the failing frame
> is unreachable in any frontend. ray-debugger.nvim detects this and recovers
> the traceback from Ray's excepthook frame automatically:
>
> * the traceback goes to the **quickfix list**, and the cursor jumps to the
>   failing line,
> * the exception and the **locals of every traceback frame** are printed in
>   the nvim-dap REPL,
> * Ray's hook frame is selected, so REPL expressions can use
>   `error = sys.exc_info()` (e.g. `error[1].args`).
>
> `:RayDebugPostMortem` shows this again later. If you prefer the native
> behaviour, pin `debugpy<=1.8.5` on the cluster.

### Ray Jobs and `working_dir`

Ray Jobs (`ray job submit --working-dir .`) and tasks started with
`runtime_env={"working_dir": ...}` run from an unpacked copy of your project
on the cluster (`/tmp/ray/session_*/runtime_resources/working_dir_files/_ray_pkg_<hash>/`).
Without help, the debugger would show those remote paths and breakpoints set
in your local files would never match.

The plugin reads the task's runtime env from the dashboard and, when it has a
`working_dir`, maps it to your local project automatically (both directions:
stack frames open your local files and local breakpoints hit on the
cluster). The local root defaults to Neovim's cwd; override it with
`attach.working_dir.local_root` (a path or `function(entry) ... end`).

### Watch mode

`:RayDebugWatch` polls the configured clusters in the background and notifies
you whenever a task starts waiting for a debugger (`:RayDebugWatch off` to
stop). Combine it with the statusline component below.

### Commands

| Command | Description |
| --- | --- |
| `:RayDebug` | List paused tasks across all configured clusters and attach |
| `:RayDebugAttach <host:port \| worker-id \| task-id>` | Attach directly, without the picker |
| `:RayDebugRefresh` | Refresh the cached list of paused tasks |
| `:RayDebugWatch [on\|off]` | Toggle background polling with notifications for new paused tasks |
| `:RayDebugPostMortem` | Show the recovered post-mortem traceback and locals again |
| `:checkhealth ray-debugger` | Diagnose configuration, `curl`, nvim-dap, and cluster reachability |

### Lua API

```lua
local ray_debugger = require("ray-debugger")

ray_debugger.setup({ ... })
ray_debugger.pick()                    -- pick and attach
ray_debugger.refresh(function(err, entries, warnings) end)
ray_debugger.attach(entry)             -- attach to a `paused()` entry
ray_debugger.attach_address("10.0.0.5:12345")
ray_debugger.watch(true)               -- start/stop background polling (toggle without args)
ray_debugger.post_mortem()             -- (re)show the post-mortem traceback
ray_debugger.paused_count()            -- number from the last refresh
ray_debugger.status()                  -- statusline component, e.g. "⏸ 2"
```

### Statusline

Add the component to lualine:

```lua
require("lualine").setup({
  sections = {
    lualine_x = { require("ray-debugger").status, "encoding", "fileformat" },
  },
})
```

## Configuration

```lua
require("ray-debugger").setup({
  -- Dashboard used when `clusters` is not set.
  dashboard_url = "http://127.0.0.1:8265",

  -- Poll for paused tasks in the background (milliseconds, 0 disables).
  poll_interval_ms = 0,

  -- Notify when new paused tasks appear while polling.
  notify_on_new = false,

  -- HTTP timeout for dashboard requests.
  request_timeout_ms = 5000,

  -- Replace the default `vim.ui.select` picker.
  picker = nil, -- fun(entries, on_choice)

  -- Multiple clusters (overrides `dashboard_url`).
  clusters = {
    { name = "local", url = "http://127.0.0.1:8265" },
    {
      name = "k8s",
      url = "http://127.0.0.1:8265",
      -- Host used for DAP connections when the dashboard and the debugger
      -- ports are reachable through different addresses/tunnels.
      dap_host = "127.0.0.1",
      headers = { Authorization = "Bearer ..." },
    },
  },

  attach = {
    -- Passed to debugpy. `false` shows Ray/pydevd frames too.
    just_my_code = false,

    -- Translate remote paths to local paths (DAP `pathMappings`).
    path_mappings = {
      { localRoot = vim.fn.getcwd(), remoteRoot = "/home/ray/app" },
    },

    -- Ray's breakpoint() suspends a helper frame first; jump to the first
    -- user frame automatically instead of showing Ray internals.
    skip_internal_frames = true,

    -- Map Ray Job / `working_dir` tasks back to the local project.
    working_dir = {
      enabled = true,
      local_root = nil, -- default: Neovim's cwd; string or function(entry)
    },

    -- Extra arguments merged into every DAP attach request.
    extra_args = {},

    -- How long to wait for debugpy to acknowledge a disconnect.
    disconnect_timeout_sec = 3,
  },

  -- Post-mortem traceback recovery (debugpy >= 1.8.6, see above).
  post_mortem = {
    enabled = true,
    quickfix = true, -- traceback in the quickfix list
    repl = true,     -- exception + locals in the nvim-dap REPL
    jump = true,     -- jump to the failing line
  },
})
```

### Remote clusters

The debugger port lives on the node that runs the task, so the address shown in
the picker (`ip:port`) must be reachable from your machine. Options:

* **SSH tunnel** (works for any cluster):

  ```bash
  ssh -N -L 127.0.0.1:12345:10.0.0.5:12345 user@cluster-head
  ```

  and set `dap_host = "127.0.0.1"` for that cluster (the port stays the same).

* **Kubernetes** — `kubectl port-forward pod/<ray-head-pod> 12345:12345` for
  each paused worker port, with `dap_host = "127.0.0.1"`.

* **Trusted network** — if the worker IPs and ports are directly reachable,
  no extra configuration is needed.

Ray binds the debugger to the node's IP address, so you do not need
`--ray-debugger-external` for the modern debugger.

## Troubleshooting

Start with:

```
:checkhealth ray-debugger
```

| Symptom | Likely cause |
| --- | --- |
| `no paused Ray tasks found` | the task has not reached `breakpoint()` yet, the worker already resumed, or the cluster uses `RAY_DEBUG=legacy` |
| `HTTP 000`/connection errors | dashboard not reachable; check `dashboard_url` and tunnels |
| Attach hangs | the debugger port is not reachable from your machine (see above) |
| Stops in Ray internals | `attach.skip_internal_frames` is on by default; check `path_mappings` for custom setups |
| Frames show `/tmp/ray/.../_ray_pkg_...` paths | set `attach.working_dir.local_root` to your project if Neovim's cwd is elsewhere |
| Post-mortem stops in `contextlib.py` | debugpy ≥ 1.8.6; the traceback is recovered into quickfix/REPL (`:RayDebugPostMortem`) |
| Nothing happens on `breakpoint()` | `debugpy>=1.8` missing on the cluster |

Notes:

* The legacy `ray debug` / `RAY_DEBUG=legacy` PDB protocol is **not** supported.
  Unset `RAY_DEBUG` or set it to `1` (the default).
* The plugin only reports tasks that are *waiting for a debugger*. Once you
  attach, the task disappears from the paused list, matching the VS Code
  extension's behaviour.

## Security

* No Node.js, no npm, no bundled binaries. The plugin is Lua and calls `curl`.
* The Ray dashboard API is plain HTTP by default and usually has no
  authentication. Treat it like any other cluster control plane: bind it to
  localhost, or reach it through a tunnel/VPN.
* A debugger port allows arbitrary code execution in the debuggee. Only forward
  it to machines you trust, and close the tunnels when you are done.

## Development

```bash
# Fetch nvim-dap into .deps/ (git-ignored) for the integration tests
make deps

# Unit tests + protocol tests
make test

# Adds a real debugpy end-to-end test (needs `pip install debugpy`)
make test-integration NVIM_DAP_PATH=/path/to/nvim-dap

# Full end-to-end tests against a real Ray cluster
# (needs `pip install "ray[default]" debugpy`): breakpoint, actor,
# post-mortem and Ray Job (working_dir) scenarios
make test-ray NVIM_DAP_PATH=/path/to/nvim-dap
# or a subset:
bash tests/integration/real_ray_cluster.sh job post-mortem
```

The unit tests spin up mock Ray dashboards and a mock DAP server; the
integration test runs a real debugpy debuggee that mimics a Ray worker; the
`test-ray` target starts a real Ray head node, runs a task that pauses on
`breakpoint()`, discovers it through the dashboard, attaches nvim-dap and
continues it. See [tests/](tests/) for details.

## License

Apache-2.0. See [LICENSE](LICENSE).

Ray, debugpy, nvim-dap and curl are separate projects under their own
(Apache-2.0 / MIT) licenses.
