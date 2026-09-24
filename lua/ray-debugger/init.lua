---ray-debugger.nvim: an open source frontend for the Ray distributed debugger.
---
---Public API:
---
---```lua
---require("ray-debugger").setup({ dashboard_url = "http://127.0.0.1:8265" })
---require("ray-debugger").pick()              -- list paused tasks and attach
---require("ray-debugger").attach(entry)       -- attach to a specific entry
---require("ray-debugger").paused(function(err, entries) end)
---require("ray-debugger").status()            -- statusline component
---```
local M = {}

local config = require("ray-debugger.config")
local dap = require("ray-debugger.dap")
local state = require("ray-debugger.state")
local ui = require("ray-debugger.ui")
local util = require("ray-debugger.util")

---@class RayDebuggerCache
---@field entries RayDebuggerEntry[]
---@field warnings string[]
---@field error string|nil
---@field updated_at integer|nil

---@type RayDebuggerCache
M.cache = {
  entries = {},
  warnings = {},
  error = nil,
  updated_at = nil,
}

M._poll_timer = nil
M._refreshing = false
M._waiters = {}

---Configure the plugin.
---@param opts? RayDebuggerConfig
---@return table M
function M.setup(opts)
  config.setup(opts)
  M._restart_polling()
  return M
end

---@return RayDebuggerCluster[]
function M.clusters()
  return config.clusters()
end

---Fetch the current paused tasks from every configured cluster.
---
---Callbacks registered while a refresh is already running are queued and run
---when that refresh finishes.
---@param cb? fun(err?: string, entries?: RayDebuggerEntry[], warnings?: string[])
function M.refresh(cb)
  if M._refreshing then
    if cb then
      M._waiters[#M._waiters + 1] = cb
    end
    return
  end
  M._refreshing = true

  local first_load = M.cache.updated_at == nil
  local previous = M.cache.entries

  state.paused(config.clusters(), function(err, entries, warnings)
    M._refreshing = false
    M.cache = {
      entries = entries or {},
      warnings = warnings or {},
      error = err,
      updated_at = util.now_ms(),
    }

    if not err and not first_load and config.options.notify_on_new then
      M._notify_new(previous, M.cache.entries)
    end
    if cb then
      cb(err, M.cache.entries, warnings)
    end

    local waiters = M._waiters
    M._waiters = {}
    for _, waiter in ipairs(waiters) do
      waiter(err, M.cache.entries, warnings)
    end
  end)
end

---Notify about tasks that started waiting since the last refresh.
---@param previous RayDebuggerEntry[]
---@param current RayDebuggerEntry[]
function M._notify_new(previous, current)
  local function key(entry)
    return entry.task_id or (entry.worker_id .. ":" .. tostring(entry.port))
  end

  local seen = {}
  for _, entry in ipairs(previous) do
    seen[key(entry)] = true
  end
  for _, entry in ipairs(current) do
    if not seen[key(entry)] then
      util.notify("new paused task: " .. entry.label, vim.log.levels.INFO)
    end
  end
end

---Refresh the cache and show the picker.
function M.pick()
  M.refresh(function(err, entries, warnings)
    if err then
      return util.notify(err, vim.log.levels.ERROR)
    end
    if warnings and #warnings > 0 then
      util.notify(table.concat(warnings, "; "), vim.log.levels.WARN)
    end
    if #entries == 0 then
      return util.notify(
        "no paused Ray tasks found. Put `breakpoint()` in a task/actor and run your app "
          .. "(and keep RAY_DEBUG unset or set to 1, not `legacy`).",
        vim.log.levels.INFO
      )
    end
    ui.pick(entries, function(entry)
      if entry then
        M.attach(entry)
      end
    end)
  end)
end

---Attach nvim-dap to a paused task entry.
---@param entry RayDebuggerEntry
---@param opts? RayDebuggerAttachOptions
---@return table|nil run_config
function M.attach(entry, opts)
  local args, err = dap.attach(entry, opts)
  if not args then
    util.notify(err, vim.log.levels.ERROR)
    return nil
  end
  return args
end

---Attach to `host:port`, a worker id, or a task id (prefix).
---@param arg string
function M.attach_address(arg)
  if not arg or arg == "" then
    return util.notify(
      "usage: :RayDebugAttach <host:port | worker-id | task-id>",
      vim.log.levels.ERROR
    )
  end

  local host, port = arg:match("^%s*([%w%.%-_]+):(%d+)%s*$")
  if host then
    return M.attach({
      host = host,
      port = tonumber(port),
      label = arg,
      cluster = "default",
    })
  end

  for _, entry in ipairs(M.cache.entries) do
    local task_prefix_matches = entry.task_id ~= nil
      and #arg >= 4
      and entry.task_id:sub(1, #arg) == arg
    if entry.worker_id == arg or task_prefix_matches then
      return M.attach(entry)
    end
  end

  util.notify(
    "no paused task matches '" .. arg .. "' (expected host:port, worker id or task id)",
    vim.log.levels.ERROR
  )
end

---Number of paused tasks from the last refresh.
---@return integer
function M.paused_count()
  if M.cache.error then
    return 0
  end
  return #M.cache.entries
end

---Statusline component. Returns an empty string when there is nothing to show.
---@return string
function M.status()
  local count = M.paused_count()
  if count == 0 then
    return ""
  end
  return "⏸ " .. count
end

---Start/stop the background refresh timer according to the configuration.
function M._restart_polling()
  if M._poll_timer then
    M._poll_timer:stop()
    M._poll_timer:close()
    M._poll_timer = nil
  end

  local interval = tonumber(config.options.poll_interval_ms) or 0
  if interval <= 0 then
    return
  end

  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  timer:start(interval, interval, function()
    vim.schedule(function()
      M.refresh()
    end)
  end)
  M._poll_timer = timer
end

return M
