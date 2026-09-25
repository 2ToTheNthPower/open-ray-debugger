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

See [docs/protocol.md](docs/protocol.md) for the full protocol details,
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
    "you/ray-debugger.nvim", -- or `dir = "/path/to/open-ray-debugger"` for a local checkout
    dependencies = { "mfussenegger/nvim-dap" },
    keys = {
      { "<leader>dr", function() require("ray-debugger").pick() end, desc = "Ray: Attach to paused task" },
      { "<leader>dR", function() require("ray-debugger").refresh() end, desc = "Ray: Refresh paused tasks" },
    },
    opts = {
      dashboard_url = "http://127.0.0.1:8265",
    },
  },
}
```

If you have not enabled the LazyVim DAP extra yet:

```lua
{ import = "lazyvim.plugins.extras.dap.core" },
```

Manual setup:

```lua
require("ray-debugger").setup({
  dashboard_url = "http://127.0.0.1:8265",
})
```

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

The frozen task shows up in `:RayDebug` with its error type.

### Commands

| Command | Description |
| --- | --- |
| `:RayDebug` | List paused tasks across all configured clusters and attach |
| `:RayDebugAttach <host:port \| worker-id \| task-id>` | Attach directly, without the picker |
| `:RayDebugRefresh` | Refresh the cached list of paused tasks |
| `:checkhealth ray-debugger` | Diagnose configuration, `curl`, nvim-dap, and cluster reachability |

### Lua API

```lua
local ray_debugger = require("ray-debugger")

ray_debugger.setup({ ... })
ray_debugger.pick()                    -- pick and attach
ray_debugger.refresh(function(err, entries, warnings) end)
ray_debugger.attach(entry)             -- attach to a `paused()` entry
ray_debugger.attach_address("10.0.0.5:12345")
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

    -- Extra arguments merged into every DAP attach request.
    extra_args = {},

    -- How long to wait for debugpy to acknowledge a disconnect.
    disconnect_timeout_sec = 3,
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
| Stops in Ray internals | set `attach.just_my_code = false` (default) and check `path_mappings` |
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
# Unit tests + protocol tests (nvim-dap integration tests need a checkout)
make test NVIM_DAP_PATH=/path/to/nvim-dap

# Adds a real debugpy end-to-end test (needs `pip install debugpy`)
make test-integration NVIM_DAP_PATH=/path/to/nvim-dap

# Full end-to-end test against a real Ray cluster
# (needs `pip install "ray[default]" debugpy`)
make test-ray NVIM_DAP_PATH=/path/to/nvim-dap
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
