---nvim-dap integration.
---
---debugpy (which Ray uses under the hood) spawns its DAP adapter inside the
---cluster when `debugpy.listen()` is called, so attaching is a plain DAP
---connection to `worker_ip:debugger_port`. nvim-dap supports that with a
---`type = "server"` adapter.
local M = {}

local config = require("ray-debugger.config")

---Name of the nvim-dap adapter registered by this plugin.
M.adapter_name = "ray"

---Paths that belong to debugger/Ray plumbing rather than the user's code.
---
---Ray's `breakpoint()` support suspends the frame of its own `set_trace`
---helper (`pydevd.settrace(stop_at_frame=...)`), so the first stop of a
---debug session can land in `ray/util/rpdb.py` instead of the task. The
---plugin walks up to the first user frame automatically.
local INTERNAL_FRAME_PATTERNS = {
  "/ray/util/rpdb%.py$",
  "/ray/util/debugpy%.py$",
  "/ray/_private/worker%.py$",
  "/ray/_private/workers/default_worker%.py$",
  "/_pydevd_bundle/",
  "/_pydev_bundle/",
  "/pydevd%.py$",
  "/debugpy/",
}

---@param frame table|nil
---@return boolean
function M.is_internal_frame(frame)
  local path = frame and frame.source and frame.source.path
  if type(path) ~= "string" then
    return false
  end
  path = path:gsub("\\", "/")
  for _, pattern in ipairs(INTERNAL_FRAME_PATTERNS) do
    if path:match(pattern) then
      return true
    end
  end
  return false
end

---Move one frame up the call stack on a specific session.
---@param session table
---@return boolean moved
local function move_up(session)
  if type(session._frame_delta) == "function" then
    if pcall(session._frame_delta, session, 1) then
      return true
    end
  end
  local ok, dap = pcall(require, "dap")
  if ok and dap.session() == session and type(dap.up) == "function" then
    dap.up()
    return true
  end
  return false
end

---Select the first user frame when a Ray task stops in Ray/debugger plumbing.
---Only applies to sessions started by this plugin and to breakpoint stops, so
---deliberate stepping into library code is not disturbed.
---@param session table
---@param body table|nil
function M._on_stopped(session, body)
  if config.options.attach.skip_internal_frames == false then
    return
  end
  if not session.config or session.config.type ~= M.adapter_name then
    return
  end
  if body and body.reason and body.reason ~= "breakpoint" then
    return
  end

  local thread_id = body and body.threadId
  local attempts = 0

  local function attempt()
    if session.closed then
      return
    end

    local thread = thread_id and session.threads and session.threads[thread_id]
    local frames = thread and thread.frames
    if (not frames or #frames == 0) and attempts < 50 then
      attempts = attempts + 1
      vim.defer_fn(attempt, 20)
      return
    end
    frames = frames or {}

    local hops = 0
    for _, frame in ipairs(frames) do
      if M.is_internal_frame(frame) then
        hops = hops + 1
      else
        break
      end
    end

    for _ = 1, hops do
      local before = session.current_frame and session.current_frame.id
      if not move_up(session) then
        return
      end
      local after = session.current_frame and session.current_frame.id
      if after == nil or after == before then
        return
      end
    end
  end

  attempt()
end

---Register the adapter with nvim-dap. Idempotent.
---@return table|nil dap The nvim-dap module.
---@return string|nil err
function M.setup_adapter()
  local ok, dap = pcall(require, "dap")
  if not ok then
    return nil,
      "nvim-dap is required to attach to Ray tasks. "
        .. "Install mfussenegger/nvim-dap (LazyVim: enable the `dap.core` extra)."
  end

  if dap.adapters[M.adapter_name] == nil then
    dap.adapters[M.adapter_name] = function(cb, cfg)
      local port = tonumber(cfg.port)
      if not port or port <= 0 then
        -- nvim-dap has no good way to surface this from inside the adapter
        -- callback, so notify and abort with a bogus-but-harmless port.
        vim.notify("ray-debugger: refusing to attach without a debugger port", vim.log.levels.ERROR)
        return cb({ type = "server", host = "127.0.0.1", port = 0 })
      end
      cb({
        type = "server",
        id = "python", -- sent as `adapterID` in the DAP initialize request
        host = cfg.host or "127.0.0.1",
        port = port,
        options = {
          source_filetype = "python",
          initialize_timeout_sec = 10,
          disconnect_timeout_sec = config.options.attach.disconnect_timeout_sec or 3,
        },
      })
    end
  end

  if dap.listeners and dap.listeners.after and dap.listeners.after.event_stopped then
    dap.listeners.after.event_stopped["ray-debugger"] = M._on_stopped
  end

  return dap
end

---Build the nvim-dap run configuration for a paused task.
---Exposed separately from `attach` so it can be unit tested.
---@param entry RayDebuggerEntry
---@param opts? RayDebuggerAttachOptions
---@return table
function M.run_config(entry, opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(config.options.attach), opts or {})

  local args = {
    type = M.adapter_name,
    request = "attach",
    name = "Ray: " .. (entry.label or (entry.host .. ":" .. tostring(entry.port))),
    host = entry.host or "127.0.0.1",
    port = tonumber(entry.port),
  }

  if opts.just_my_code ~= nil then
    args.justMyCode = opts.just_my_code
  end
  if opts.path_mappings and #opts.path_mappings > 0 then
    args.pathMappings = opts.path_mappings
  end
  if opts.extra_args then
    args = vim.tbl_deep_extend("force", args, opts.extra_args)
  end

  return args
end

---Attach nvim-dap to a paused Ray task.
---@param entry RayDebuggerEntry
---@param opts? RayDebuggerAttachOptions
---@return table|nil run_config
---@return string|nil err
function M.attach(entry, opts)
  local dap, err = M.setup_adapter()
  if not dap then
    return nil, err
  end

  local args = M.run_config(entry, opts)
  if not args.port or args.port <= 0 then
    return nil, "paused task has no debugger port (it may have resumed already)"
  end

  dap.run(args)
  return args
end

return M
