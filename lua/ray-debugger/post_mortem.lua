---Post-mortem traceback recovery.
---
---With `RAY_DEBUG_POST_MORTEM=1`, Ray freezes a failing task inside
---`ray/util/debugpy.py:_debugpy_excepthook`, where `error = sys.exc_info()`,
---and asks pydevd to stop on the exception. debugpy <= 1.8.5 then reports the
---traceback frames, but debugpy >= 1.8.6 reports the *current* stack (Ray's
---worker loop) and fails the `exceptionInfo` request, so the failing frame is
---not reachable from the debugger UI at all.
---
---When that happens this module evaluates a small expression in the
---`_debugpy_excepthook` frame to recover the traceback and the locals of
---every traceback frame, then puts the traceback in the quickfix list, prints
---the locals in the nvim-dap REPL and jumps to the failing line.
local M = {}

local config = require("ray-debugger.config")
local util = require("ray-debugger.util")

---Names of Ray frames that hold `error = sys.exc_info()`.
M.hook_frame_names = { _debugpy_excepthook = true }

---Python expression evaluated in the hook frame. It returns a JSON string with
---the exception, the worker cwd, and the traceback frames with their locals.
---`reprlib` is used so that broken `__repr__` implementations and huge values
---cannot break the recovery.
M.expression = table.concat({
  "(lambda E, R, tb: __import__('json').dumps({",
  "'type': getattr(E[0], '__qualname__', str(E[0])),",
  "'message': str(E[1]),",
  "'cwd': __import__('os').getcwd(),",
  "'frames': [{'file': f.f_code.co_filename, 'line': l, 'name': f.f_code.co_name,",
  "'locals': {str(k): R.repr(v) for k, v in list(f.f_locals.items())[:30]}}",
  "for f, l in tb.walk_tb(E[2])]}))",
  "(error,",
  "(lambda r: (setattr(r, 'maxstring', 160), setattr(r, 'maxother', 160),",
  "setattr(r, 'maxlong', 60), r)[-1])(__import__('reprlib').Repr()),",
  "__import__('traceback'))",
}, " ")

---Find Ray's excepthook frame in a stack trace.
---@param frames table[]
---@return table|nil
function M.find_hook_frame(frames)
  for _, frame in ipairs(frames or {}) do
    if M.hook_frame_names[frame.name] then
      return frame
    end
  end
  return nil
end

---Undo Python's `repr()` of a `str` (debugpy returns evaluate results as repr).
---@param value string
---@return string
function M.decode_python_str(value)
  local quote = value:sub(1, 1)
  if (quote ~= "'" and quote ~= '"') or #value < 2 or value:sub(-1) ~= quote then
    return value
  end
  local escapes = { ["\\"] = "\\", ["'"] = "'", ['"'] = '"', n = "\n", t = "\t", r = "\r" }
  return (
    value:sub(2, -2):gsub("\\(.)", function(char)
      return escapes[char] or ("\\" .. char)
    end)
  )
end

---Parse the evaluate result of `M.expression`.
---@param result string
---@return table|nil info
---@return string|nil err
function M.parse(result)
  if type(result) ~= "string" then
    return nil, "empty evaluate result"
  end
  local ok, info = pcall(vim.json.decode, M.decode_python_str(result))
  if not ok or type(info) ~= "table" or type(info.frames) ~= "table" then
    return nil, "could not parse the recovered traceback"
  end
  return info
end

---Translate a path from the cluster to the local machine with DAP pathMappings.
---`remoteRoot = "."` stands for the worker's cwd (as in debugpy).
---@param path string
---@param mappings table[]|nil
---@param cwd string|nil
---@return string
function M.map_path(path, mappings, cwd)
  for _, mapping in ipairs(mappings or {}) do
    local remote = mapping.remoteRoot == "." and cwd or mapping.remoteRoot
    if type(remote) == "string" and remote ~= "" and type(mapping.localRoot) == "string" then
      remote = remote:gsub("[/\\]+$", "")
      if path == remote or path:sub(1, #remote + 1) == remote .. "/" then
        return (mapping.localRoot:gsub("[/\\]+$", "")) .. path:sub(#remote + 1)
      end
    end
  end
  return path
end

---Index of the innermost frame that belongs to the user's code.
---@param frames table[]
---@return integer|nil
function M.user_frame_index(frames)
  local is_internal = require("ray-debugger.dap").is_internal_frame
  for index = #frames, 1, -1 do
    local file = frames[index].file
    if
      type(file) == "string"
      and not file:match("%.pyx$")
      and not is_internal({ source = { path = file } })
    then
      return index
    end
  end
  return nil
end

---Render the recovered information as REPL lines.
---@param info table
---@param user_index integer|nil
---@return string[]
function M.format_report(info, user_index)
  local lines = {
    string.format("Ray post-mortem: %s: %s", info.type or "Exception", info.message or ""),
    "Traceback (most recent call last):",
  }
  for _, frame in ipairs(info.frames) do
    lines[#lines + 1] =
      string.format('  File "%s", line %s, in %s', frame.file, tostring(frame.line), frame.name)
  end
  local frame = user_index and info.frames[user_index]
  if frame then
    lines[#lines + 1] =
      string.format("Locals of %s() at %s:%s:", frame.name, frame.file, tostring(frame.line))
    local names = vim.tbl_keys(frame.locals or {})
    table.sort(names)
    for _, name in ipairs(names) do
      lines[#lines + 1] = string.format("  %s = %s", name, frame.locals[name])
    end
  end
  lines[#lines + 1] = "(the selected frame holds `error = sys.exc_info()` for further inspection)"
  return lines
end

---The most recent recovery, for `:RayDebugPostMortem`.
---@type table|nil
M.last = nil

---Show recovered post-mortem information.
---@param session table
---@param info table
---@param hook_frame table|nil
function M.present(session, info, hook_frame)
  local opts = config.options.post_mortem
  local mappings = session.config and session.config.pathMappings
  for _, frame in ipairs(info.frames) do
    frame.file = M.map_path(frame.file, mappings, info.cwd)
  end

  local user_index = M.user_frame_index(info.frames)
  M.last = { info = info, user_index = user_index }

  if opts.quickfix ~= false then
    local items = {}
    for _, frame in ipairs(info.frames) do
      items[#items + 1] = { filename = frame.file, lnum = frame.line, text = frame.name .. "()" }
    end
    vim.fn.setqflist({}, " ", {
      title = string.format(
        "Ray post-mortem: %s: %s",
        info.type or "Exception",
        info.message or ""
      ),
      items = items,
    })
  end

  if opts.repl ~= false then
    local ok, repl = pcall(require, "dap.repl")
    if ok and type(repl.append) == "function" then
      for _, line in ipairs(M.format_report(info, user_index)) do
        pcall(repl.append, line)
      end
    end
  end

  -- Select Ray's hook frame so REPL expressions can use `error`.
  if hook_frame and type(session._frame_set) == "function" then
    pcall(session._frame_set, session, hook_frame)
  end

  local frame = user_index and info.frames[user_index]
  if
    opts.jump ~= false
    and frame
    and opts.quickfix ~= false
    and vim.fn.filereadable(frame.file) == 1
  then
    pcall(vim.cmd, "cc " .. user_index)
  end

  local where = frame
      and string.format(" in %s() at %s:%s", frame.name, frame.file, tostring(frame.line))
    or ""
  util.notify(
    string.format(
      "post-mortem %s: %s%s (traceback in quickfix, locals in the DAP REPL)",
      info.type,
      info.message,
      where
    ),
    vim.log.levels.WARN
  )
end

---Recover and present the traceback of a frozen Ray task.
---@param session table
---@param hook_frame table
---@param cb? fun(err?: string, info?: table)
function M.run(session, hook_frame, cb)
  cb = cb or function() end
  session:evaluate(
    { expression = M.expression, frameId = hook_frame.id, context = "repl" },
    function(err, response)
      if err or not response then
        local msg = "could not recover the post-mortem traceback: "
          .. tostring(err and (err.message or err) or "no response")
        util.notify(msg, vim.log.levels.WARN)
        return cb(msg)
      end
      local info, parse_err = M.parse(response.result)
      if not info then
        util.notify(parse_err, vim.log.levels.WARN)
        return cb(parse_err)
      end
      M.present(session, info, hook_frame)
      cb(nil, info)
    end
  )
end

return M
