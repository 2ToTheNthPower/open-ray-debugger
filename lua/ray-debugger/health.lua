---`:checkhealth ray-debugger` support.
local M = {}

local config = require("ray-debugger.config")
local state = require("ray-debugger.state")

---Run a dashboard request and wait for the result (health checks are synchronous).
---@param cluster RayDebuggerCluster
---@param path string
---@param params? table[]
---@return string|nil err
---@return table|nil data
local function blocking_api_get(cluster, path, params)
  local done, err, data = false, nil, nil
  state.api_get(cluster, path, params, function(api_err, api_data)
    err, data = api_err, api_data
    done = true
  end)
  vim.wait(config.options.request_timeout_ms + 1000, function()
    return done
  end, 50)
  if not done then
    return "request timed out", nil
  end
  return err, data
end

function M.check()
  local health = vim.health or require("health")
  health.start("ray-debugger.nvim")

  -- Neovim version / async support.
  if vim.system then
    health.ok("Neovim supports `vim.system` (asynchronous HTTP)")
  else
    health.warn("Neovim is older than 0.10; dashboard requests run synchronously")
  end

  -- curl.
  if vim.fn.executable("curl") == 1 then
    health.ok("`curl` is available")
  else
    health.error("`curl` was not found in PATH", {
      "ray-debugger uses curl to talk to the Ray dashboard",
      "install curl (https://curl.se/)",
    })
  end

  -- nvim-dap.
  local has_dap = pcall(require, "dap")
  if has_dap then
    health.ok("nvim-dap is installed")
  else
    health.error("nvim-dap is not installed", {
      "ray-debugger uses nvim-dap to attach to paused tasks",
      "install mfussenegger/nvim-dap",
      "LazyVim: enable the `lazyvim.plugins.extras.dap.core` extra",
    })
  end

  -- Ray debugger mode.
  local ray_debug = vim.env.RAY_DEBUG
  if ray_debug == "legacy" then
    health.warn("RAY_DEBUG=legacy is set in your local environment", {
      "the legacy PDB protocol is not supported by this plugin",
      "make sure the cluster/runtime env uses the default modern debugger (unset RAY_DEBUG or set it to `1`)",
    })
  else
    health.ok("local RAY_DEBUG is not `legacy` (make sure the cluster runtime env matches)")
  end
  if vim.env.RAY_DEBUG_POST_MORTEM ~= "1" then
    health.info(
      "Set `RAY_DEBUG_POST_MORTEM=1` in the cluster runtime env to freeze failing tasks for post-mortem debugging"
    )
  end

  -- Clusters.
  local clusters = config.clusters()
  health.start("Ray clusters")
  for _, cluster in ipairs(clusters) do
    local err, data = blocking_api_get(cluster, "/api/v0/workers", {
      { "detail", 1 },
      { "limit", 10000 },
    })
    if err then
      health.error(string.format("%s (%s): %s", cluster.name, cluster.url, err), {
        "is the Ray dashboard running and reachable?",
        "for remote clusters, forward the dashboard port (e.g. `kubectl port-forward`)",
      })
    else
      local workers = state.rows_from_data(data)
      local paused = 0
      for _, worker in ipairs(workers) do
        if worker.is_alive ~= false and (tonumber(worker.num_paused_threads) or 0) > 0 then
          paused = paused + 1
        end
      end
      health.ok(
        string.format(
          "%s (%s): %d worker(s), %d paused",
          cluster.name,
          cluster.url,
          #workers,
          paused
        )
      )
      if paused > 0 then
        health.info("run `:RayDebug` to pick a paused task and attach")
      end
    end
  end

  health.start("Usage notes")
  health.info("put `breakpoint()` in a Ray task or actor, then run your application")
  health.info(
    "Ray clusters on other machines need their debugger ports reachable (SSH tunnel or `--ray-debugger-external`)"
  )
end

return M
