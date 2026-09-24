-- A tiny HTTP server that mimics the Ray dashboard State API for tests.
local M = {}

local uv = vim.uv or vim.loop

---Return the bound `ip, port` for a luv TCP handle.
---Older luv returns `ip, port`, newer luv returns a `{ family, ip, port }` table.
---@param handle table
---@return string|nil
---@return integer|nil
local function bound_address(handle)
  local first, second = handle:getsockname()
  if type(first) == "table" then
    return first.ip, first.port
  end
  return first, second
end

---@param query table[] list of {key, value} pairs
---@param key string
---@return string|nil
local function query_get(query, key)
  for _, pair in ipairs(query) do
    if pair[1] == key then
      return pair[2]
    end
  end
  return nil
end

local function decode(str)
  return (
    str
      :gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)
      :gsub("+", " ")
  )
end

---Wrap a payload in Ray's REST envelope.
---@param rows table[]
---@return string
function M.envelope(rows)
  return vim.json.encode({
    result = true,
    msg = "",
    data = {
      result = rows,
      total = #rows,
      num_after_truncation = #rows,
      num_filtered = #rows,
    },
  })
end

---Start the mock dashboard.
---@param routes table<string, fun(query: table[], state: table): { status?: integer, body: string }>
---@return table handle
function M.start(routes)
  local server = assert(uv.new_tcp())
  server:bind("127.0.0.1", 0)
  local _, port = bound_address(server)

  local handle = {
    requests = {},
    port = port,
    url = string.format("http://127.0.0.1:%d", port),
  }

  server:listen(32, function(err)
    if err then
      return
    end
    local client = assert(uv.new_tcp())
    server:accept(client)

    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        client:close()
        return
      end
      buffer = buffer .. chunk

      local header_end = buffer:find("\r\n\r\n", 1, true)
      if not header_end then
        return
      end

      local request_line = buffer:sub(1, (buffer:find("\r\n") or #buffer) - 1)
      local method, target = request_line:match("^(%S+)%s+(%S+)")
      local path, query_string = target:match("^([^?]*)%??(.*)$")

      local query = {}
      for pair in (query_string or ""):gmatch("[^&]+") do
        local key, value = pair:match("^([^=]*)=(.*)$")
        if key then
          query[#query + 1] = { decode(key), decode(value) }
        end
      end

      handle.requests[#handle.requests + 1] = {
        method = method,
        path = path,
        query = query,
      }

      local handler = routes[path]
      local status, body
      if handler then
        local response = handler(query, handle)
        status = response.status or 200
        body = response.body
      else
        status = 404
        body = vim.json.encode({ result = false, msg = "not found", data = nil })
      end

      client:write(
        string.format(
          "HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
          status,
          #body,
          body
        )
      )
      client:close()
    end)
  end)

  handle.stop = function()
    pcall(function()
      server:close()
    end)
  end

  handle.query_get = query_get

  return handle
end

return M
