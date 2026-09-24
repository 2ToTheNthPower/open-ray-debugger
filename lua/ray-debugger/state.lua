---Ray cluster discovery through the open-source dashboard State REST API.
---
---The Ray debugger works like this (all of this is open source, in the Ray
---repository itself):
---
---1. A task or actor calls `breakpoint()`. Ray's worker installs a
---   `PYTHONBREAKPOINT` hook that routes this to the distributed debugger.
---2. The worker starts a debugpy server on an ephemeral port and records that
---   port in the cluster's worker state (`WorkerState.debugger_port`).
---3. While waiting for a debugger to attach, the worker increments
---   `WorkerState.num_paused_threads`.
---4. A frontend queries the dashboard (`/api/v0/workers`) to find those
---   workers and connects to `ip:debugger_port` using the Debug Adapter
---   Protocol (debugpy's server speaks DAP directly).
---
---This module implements steps 1-4 for Neovim. Nothing here is Anyscale
---specific: the endpoints and the debug protocol are part of Ray itself.
local M = {}

local config = require("ray-debugger.config")
local http = require("ray-debugger.http")
local util = require("ray-debugger.util")

---@class RayDebuggerEntry
---@field label string Formatted, human readable label for the picker.
---@field cluster string Cluster name.
---@field cluster_url string Dashboard URL of the cluster.
---@field host string Host to reach the debugger on.
---@field port integer Debugger (DAP) port.
---@field worker_id string
---@field pid? integer
---@field task_id? string
---@field name? string
---@field func_or_class_name? string
---@field state? string
---@field error_type? string
---@field actor_id? string
---@field job_id? string
---@field is_debugger_paused? boolean

---GET a JSON document from the dashboard State API.
---@param cluster RayDebuggerCluster
---@param path string
---@param params? table[] List of `{ key, value }` query pairs.
---@param cb fun(err?: string, data?: table)
function M.api_get(cluster, path, params, cb)
  local url = util.join_url(cluster.url, path)
  local query = util.encode_query(params)
  if query ~= "" then
    url = url .. "?" .. query
  end

  http.get(url, {
    timeout_ms = config.options.request_timeout_ms,
    headers = cluster.headers,
  }, function(err, res)
    if err then
      return cb(err)
    end
    if res.status ~= 200 then
      local detail = ""
      if res.body and res.body ~= "" then
        detail = ": " .. res.body:gsub("%s+", " "):sub(1, 200)
      end
      return cb(string.format("HTTP %d from %s%s", res.status, cluster.name, detail))
    end

    local ok, decoded = pcall(vim.json.decode, res.body)
    if not ok or type(decoded) ~= "table" then
      return cb("invalid JSON response from " .. cluster.name)
    end
    if decoded.result ~= true then
      local msg = decoded.msg
      if type(msg) ~= "string" or msg == "" then
        msg = "request to " .. cluster.name .. " failed"
      end
      return cb(msg)
    end
    cb(nil, decoded.data)
  end)
end

---@param value any
---@return string|nil
local function non_empty(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---Pick the most interesting task out of the tasks running on one worker.
---@param tasks table[]
---@return table|nil
function M.pick_task(tasks)
  tasks = tasks or {}

  local function newest(candidates)
    local best
    for _, task in ipairs(candidates) do
      if not best or (tonumber(task.start_time_ms) or 0) > (tonumber(best.start_time_ms) or 0) then
        best = task
      end
    end
    return best
  end

  local function matching(predicate)
    local out = {}
    for _, task in ipairs(tasks) do
      if predicate(task) then
        out[#out + 1] = task
      end
    end
    return out
  end

  local paused = matching(function(task)
    return task.is_debugger_paused == true
  end)
  if #paused > 0 then
    return newest(paused)
  end

  local running = matching(function(task)
    return task.state == "RUNNING"
  end)
  if #running > 0 then
    return newest(running)
  end

  return newest(tasks)
end

---Turn a paused worker (and its task, when known) into a picker entry.
---@param cluster RayDebuggerCluster
---@param worker table
---@param task? table
---@return RayDebuggerEntry
function M.entry_from_worker(cluster, worker, task)
  local entry = {
    cluster = cluster.name,
    cluster_url = cluster.url,
    host = cluster.dap_host or non_empty(worker.ip) or non_empty(worker.node_ip) or "127.0.0.1",
    port = tonumber(worker.debugger_port),
    worker_id = worker.worker_id,
    pid = worker.pid,
    task_id = task and non_empty(task.task_id) or nil,
    name = task and non_empty(task.name) or nil,
    func_or_class_name = task and non_empty(task.func_or_class_name) or nil,
    state = task and non_empty(task.state) or nil,
    error_type = task and non_empty(task.error_type) or nil,
    actor_id = task and non_empty(task.actor_id) or nil,
    job_id = task and non_empty(task.job_id) or nil,
    is_debugger_paused = task and task.is_debugger_paused or nil,
  }
  entry.label = util.entry_label(entry)
  return entry
end

---Find the task a paused worker is currently executing.
---@param cluster RayDebuggerCluster
---@param worker table
---@param cb fun(err?: string, task?: table)
function M.task_for_worker(cluster, worker, cb)
  M.api_get(cluster, "/api/v0/tasks", {
    { "detail", 1 },
    { "limit", 50 },
    { "filter_keys", "worker_id" },
    { "filter_predicates", "=" },
    { "filter_values", worker.worker_id },
  }, function(err, data)
    if err then
      return cb(err)
    end
    cb(nil, M.pick_task(data and data.result or {}))
  end)
end

---List the paused workers of a single cluster.
---@param cluster RayDebuggerCluster
---@param cb fun(err?: string, entries?: RayDebuggerEntry[], warning?: string)
function M.paused_in_cluster(cluster, cb)
  M.api_get(cluster, "/api/v0/workers", {
    { "detail", 1 },
    { "limit", 10000 },
  }, function(err, data)
    if err then
      return cb(err)
    end

    local workers = (data and data.result) or {}

    -- `num_paused_threads` was added to worker state after the debugger
    -- itself; fall back to "has an open debugger port" on older clusters.
    local has_paused_counter = false
    for _, worker in ipairs(workers) do
      if worker.num_paused_threads ~= nil then
        has_paused_counter = true
        break
      end
    end

    local paused = {}
    for _, worker in ipairs(workers) do
      local port = tonumber(worker.debugger_port)
      if worker.is_alive ~= false and port and port > 0 then
        local is_paused
        if has_paused_counter then
          is_paused = (tonumber(worker.num_paused_threads) or 0) > 0
        else
          is_paused = true
        end
        if is_paused then
          paused[#paused + 1] = worker
        end
      end
    end

    if #paused == 0 then
      return cb(nil, {})
    end

    local entries, warnings = {}, {}
    local remaining = #paused
    for _, worker in ipairs(paused) do
      M.task_for_worker(cluster, worker, function(task_err, task)
        if task_err then
          warnings[#warnings + 1] = task_err
        end
        entries[#entries + 1] = M.entry_from_worker(cluster, worker, task)
        remaining = remaining - 1
        if remaining == 0 then
          table.sort(entries, function(a, b)
            return a.label < b.label
          end)
          cb(nil, entries, #warnings > 0 and table.concat(warnings, "; ") or nil)
        end
      end)
    end
  end)
end

---List paused tasks across all configured clusters.
---@param clusters RayDebuggerCluster[]
---@param cb fun(err?: string, entries?: RayDebuggerEntry[], warnings?: string[])
function M.paused(clusters, cb)
  clusters = clusters or config.clusters()
  if #clusters == 0 then
    return cb("no clusters configured")
  end

  local all, warnings, errors = {}, {}, {}
  local remaining = #clusters

  for _, cluster in ipairs(clusters) do
    M.paused_in_cluster(cluster, function(err, entries, warning)
      if err then
        errors[#errors + 1] = cluster.name .. ": " .. err
      else
        vim.list_extend(all, entries or {})
        if warning then
          warnings[#warnings + 1] = cluster.name .. ": " .. warning
        end
      end
      remaining = remaining - 1
      if remaining == 0 then
        if #all == 0 and #errors == #clusters then
          return cb(table.concat(errors, "; "))
        end
        table.sort(all, function(a, b)
          return a.label < b.label
        end)
        for _, error in ipairs(errors) do
          warnings[#warnings + 1] = error
        end
        cb(nil, all, warnings)
      end
    end)
  end
end

return M
