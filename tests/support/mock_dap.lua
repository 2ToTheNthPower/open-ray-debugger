-- A minimal DAP server used to test the nvim-dap integration without a
-- Ray cluster. It understands just enough of the protocol to accept an
-- attach session and emit a `stopped` event.
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

local function encode(msg)
  local body = vim.json.encode(msg)
  return string.format("Content-Length: %d\r\n\r\n%s", #body, body)
end

---Start the mock DAP server.
---@param opts? { source_path?: string, line?: integer }
---@return table handle
function M.start(opts)
  opts = opts or {}
  local source_path = opts.source_path or "/tmp/ray-debugger-test.py"
  local line = opts.line or 1

  local server = assert(uv.new_tcp())
  server:bind("127.0.0.1", 0)
  local _, port = bound_address(server)

  local handle = {
    port = port,
    requests = {}, -- { command = ..., arguments = ... }
    events = {}, -- { event = ..., body = ... }
    seq = 0,
  }

  local function next_seq()
    handle.seq = handle.seq + 1
    return handle.seq
  end

  local function respond(client, request, body)
    client:write(encode({
      seq = next_seq(),
      type = "response",
      request_seq = request.seq,
      success = true,
      command = request.command,
      body = body or {},
    }))
  end

  local function event(client, name, body)
    handle.events[#handle.events + 1] = { event = name, body = body }
    client:write(encode({
      seq = next_seq(),
      type = "event",
      event = name,
      body = body,
    }))
  end

  local function handle_message(client, msg)
    if msg.type ~= "request" then
      return
    end
    handle.requests[#handle.requests + 1] = {
      command = msg.command,
      arguments = msg.arguments,
    }

    if msg.command == "initialize" then
      respond(client, msg, {
        supportsConfigurationDoneRequest = true,
        supportsSetBreakpoints = true,
        supportsConditionalBreakpoints = true,
      })
    elseif msg.command == "attach" then
      respond(client, msg)
      -- DAP flow: the adapter announces it is ready for breakpoint
      -- configuration with the `initialized` event.
      event(client, "initialized", {})
    elseif msg.command == "configurationDone" then
      respond(client, msg)
      event(client, "stopped", {
        reason = "breakpoint",
        threadId = 1,
        allThreadsStopped = true,
      })
    elseif msg.command == "threads" then
      respond(client, msg, { threads = { { id = 1, name = "MainThread" } } })
    elseif msg.command == "stackTrace" then
      respond(client, msg, {
        stackFrames = {
          {
            id = 1,
            name = "f",
            source = { name = source_path, path = source_path },
            line = line,
            column = 1,
          },
        },
        totalFrames = 1,
      })
    elseif msg.command == "scopes" then
      respond(client, msg, {
        scopes = {
          { name = "Locals", variablesReference = 1, expensive = false },
        },
      })
    elseif msg.command == "variables" then
      respond(client, msg, { variables = { { name = "x", value = "42", variablesReference = 0 } } })
    elseif msg.command == "setBreakpoints" then
      local breakpoints = {}
      for _, bp in ipairs(msg.arguments.breakpoints or {}) do
        breakpoints[#breakpoints + 1] = { verified = true, line = bp.line }
      end
      respond(client, msg, { breakpoints = breakpoints })
    else
      respond(client, msg)
    end
  end

  server:listen(32, function(err)
    if err then
      return
    end
    local client = assert(uv.new_tcp())
    server:accept(client)
    handle.client = client

    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        client:close()
        return
      end
      buffer = buffer .. chunk
      while true do
        local header_end = buffer:find("\r\n\r\n", 1, true)
        if not header_end then
          return
        end
        local header = buffer:sub(1, header_end - 1)
        local length = tonumber(header:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
        if not length then
          buffer = ""
          return
        end
        local body_start = header_end + 4
        if #buffer < body_start + length - 1 then
          return
        end
        local body = buffer:sub(body_start, body_start + length - 1)
        buffer = buffer:sub(body_start + length)
        local ok, msg = pcall(vim.json.decode, body)
        if ok then
          handle_message(client, msg)
        end
      end
    end)
  end)

  handle.stop = function()
    if handle.client then
      pcall(function()
        handle.client:close()
      end)
    end
    pcall(function()
      server:close()
    end)
  end

  return handle
end

return M
