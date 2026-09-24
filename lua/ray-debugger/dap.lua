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
