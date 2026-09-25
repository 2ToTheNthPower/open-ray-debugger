---Configuration handling for ray-debugger.nvim.
---
---Everything is stored in a single table so that the rest of the plugin can
---read user options without threading them through every call.
local M = {}

---@class RayDebuggerCluster
---@field name string Human readable cluster name (shown in the picker).
---@field url string Ray dashboard base URL, e.g. `http://127.0.0.1:8265`.
---@field dap_host? string Override the host used for debugger connections. Useful when
---  the dashboard is reachable through a tunnel but the debug port is not.
---@field headers? table<string, string> Extra HTTP headers for the dashboard requests.

---@class RayDebuggerAttachOptions
---@field just_my_code? boolean Passed to debugpy as `justMyCode`.
---@field path_mappings? table[] `pathMappings` entries (`{ localRoot, remoteRoot }`)
---  used to translate paths between the local machine and the cluster.
---@field skip_internal_frames? boolean When Ray's `breakpoint()` suspends a
---  frame inside Ray/debugpy plumbing, select the first user frame instead.
---@field working_dir? { enabled?: boolean, local_root?: string|fun(entry: RayDebuggerEntry): string|nil }
---  Map files of tasks that run from a `working_dir` runtime env (every Ray Job)
---  to `local_root` (default: Neovim's cwd).
---@field extra_args? table Extra arguments merged into every DAP `attach` request.
---@field disconnect_timeout_sec? number How long to wait for the adapter to disconnect.

---@class RayDebuggerPostMortemOptions
---@field enabled? boolean Recover the traceback when debugpy reports Ray's excepthook stack.
---@field quickfix? boolean Put the recovered traceback in the quickfix list.
---@field repl? boolean Print the exception and the failing frame's locals in the DAP REPL.
---@field jump? boolean Jump to the failing line.

---@class RayDebuggerConfig
---@field dashboard_url string Dashboard URL used when `clusters` is not set.
---@field clusters? RayDebuggerCluster[] Multiple clusters to poll.
---@field request_timeout_ms integer HTTP timeout for dashboard requests.
---@field poll_interval_ms integer Refresh interval for the paused task cache. 0 disables polling.
---@field notify_on_new boolean Notify when new paused tasks appear while polling.
---@field picker? fun(entries: RayDebuggerEntry[], on_choice: fun(entry?: RayDebuggerEntry))
---  Custom picker. Defaults to `vim.ui.select`.
---@field attach RayDebuggerAttachOptions
---@field post_mortem RayDebuggerPostMortemOptions

---@type RayDebuggerConfig
M.defaults = {
  dashboard_url = "http://127.0.0.1:8265",
  clusters = nil,
  request_timeout_ms = 5000,
  poll_interval_ms = 0,
  notify_on_new = false,
  picker = nil,
  attach = {
    just_my_code = false,
    path_mappings = nil,
    skip_internal_frames = true,
    working_dir = {
      enabled = true,
      local_root = nil,
    },
    extra_args = {},
    disconnect_timeout_sec = 3,
  },
  post_mortem = {
    enabled = true,
    quickfix = true,
    repl = true,
    jump = true,
  },
}

---@type RayDebuggerConfig
M.options = vim.deepcopy(M.defaults)

---Normalize the configured clusters into a list.
---@return RayDebuggerCluster[]
function M.clusters()
  local opts = M.options
  local clusters = {}
  if opts.clusters and #opts.clusters > 0 then
    for i, cluster in ipairs(opts.clusters) do
      if type(cluster) == "string" then
        cluster = { name = "cluster-" .. i, url = cluster }
      end
      clusters[#clusters + 1] = {
        name = cluster.name or ("cluster-" .. i),
        url = cluster.url,
        dap_host = cluster.dap_host,
        headers = cluster.headers,
      }
    end
  else
    clusters[1] = { name = "default", url = opts.dashboard_url }
  end
  return clusters
end

---Apply user options.
---@param opts? RayDebuggerConfig
---@return RayDebuggerConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  local clusters = M.clusters()
  for _, cluster in ipairs(clusters) do
    if type(cluster.url) ~= "string" or cluster.url == "" then
      error("ray-debugger: every cluster needs a `url` (got " .. vim.inspect(cluster.url) .. ")")
    end
  end

  if M.options.request_timeout_ms <= 0 then
    M.options.request_timeout_ms = M.defaults.request_timeout_ms
  end

  return M.options
end

return M
