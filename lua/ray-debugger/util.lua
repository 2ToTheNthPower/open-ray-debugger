---Small helpers shared across ray-debugger.nvim.
local M = {}

---Join a base URL and a path with exactly one slash in between.
---@param base string
---@param path string
---@return string
function M.join_url(base, path)
  return (base:gsub("/+$", "")) .. "/" .. (path:gsub("^/+", ""))
end

---Percent-encode a query string component (RFC 3986).
---Implemented by hand so the plugin also works on Neovim versions where
---`vim.uri_encode` does not accept an options argument.
---@param value string|number
---@return string
function M.urlencode(value)
  return (
    tostring(value):gsub("([^%w%-%_%.%~])", function(char)
      return string.format("%%%02X", string.byte(char))
    end)
  )
end

---Encode a list of `{ key, value }` pairs into a query string.
---@param params table[]|nil
---@return string
function M.encode_query(params)
  if not params then
    return ""
  end
  local parts = {}
  for _, pair in ipairs(params) do
    parts[#parts + 1] = M.urlencode(pair[1]) .. "=" .. M.urlencode(pair[2])
  end
  return table.concat(parts, "&")
end

---Shorten an id for display.
---@param id string|nil
---@return string
function M.short_id(id)
  if not id then
    return "?"
  end
  if #id <= 10 then
    return id
  end
  return id:sub(1, 10)
end

---Format a paused task entry for the picker.
---@param entry RayDebuggerEntry
---@return string
function M.entry_label(entry)
  local parts = {}
  if entry.cluster and entry.cluster ~= "default" then
    parts[#parts + 1] = "[" .. entry.cluster .. "]"
  end
  parts[#parts + 1] = entry.func_or_class_name
    or entry.name
    or ("worker " .. M.short_id(entry.worker_id))
  if entry.actor_id then
    parts[#parts + 1] = "(actor)"
  end
  parts[#parts + 1] = entry.state or "UNKNOWN"
  if entry.error_type then
    parts[#parts + 1] = "[" .. entry.error_type .. "]"
  end
  parts[#parts + 1] = "@ " .. entry.host .. ":" .. tostring(entry.port)
  return table.concat(parts, " ")
end

---Notify with a consistent prefix.
---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify("ray-debugger: " .. msg, level or vim.log.levels.INFO)
end

---@return integer
function M.now_ms()
  return math.floor(vim.uv.hrtime() / 1e6)
end

return M
