---Minimal HTTP GET client.
---
---Ray's dashboard exposes a plain JSON REST API. We shell out to `curl`
---(which is available on every platform Neovim runs on and is itself open
---source) instead of pulling in a Node/npm based client or an extra Lua
---dependency.
local M = {}

---References to in-flight curl processes (see `M.get`).
M._running = {}

---@class RayDebuggerHttpResponse
---@field status integer HTTP status code.
---@field body string Response body.

---@param timeout_ms integer
---@return string
local function curl_timeout_arg(timeout_ms)
  -- curl's --max-time is in seconds; always leave at least one second.
  return string.format("%.1f", math.max(timeout_ms, 1000) / 1000)
end

---@return boolean
local function has_curl()
  if M._has_curl == nil then
    M._has_curl = vim.fn.executable("curl") == 1
  end
  return M._has_curl
end

---Build the curl command line.
---@param url string
---@param opts { timeout_ms?: integer, headers?: table<string,string>|nil }
---@return string[]
local function curl_cmd(url, opts)
  local cmd = {
    "curl",
    "-sS", -- silent, but print errors
    "--max-time",
    curl_timeout_arg(opts.timeout_ms or 5000),
    "-X",
    "GET",
    "-w",
    "\n%{http_code}",
    "-H",
    "Accept: application/json",
  }
  for key, value in pairs(opts.headers or {}) do
    cmd[#cmd + 1] = "-H"
    cmd[#cmd + 1] = key .. ": " .. value
  end
  cmd[#cmd + 1] = url
  return cmd
end

---Split curl's `-w "\n%{http_code}"` trailer from the body.
---@param stdout string
---@return string body
---@return integer|nil status
local function split_status(stdout)
  local body, status = stdout:match("^(.*)\n(%d%d%d)$")
  if not status then
    return stdout, nil
  end
  return body, tonumber(status)
end

---Asynchronous GET. The callback runs in the main loop.
---@param url string
---@param opts { timeout_ms?: integer, headers?: table<string,string>|nil }|nil
---@param cb fun(err?: string, res?: RayDebuggerHttpResponse)
function M.get(url, opts, cb)
  opts = opts or {}
  if not has_curl() then
    return cb("`curl` executable not found; ray-debugger needs curl for dashboard requests")
  end

  local cmd = curl_cmd(url, opts)

  if vim.system then
    -- Keep a reference to the running process: if the SystemObj is garbage
    -- collected, Neovim may kill the process before the callback fires.
    local proc
    local ok, started = pcall(vim.system, cmd, { text = true }, function(res)
      M._running[proc] = nil
      local stdout = res.stdout or ""
      local stderr = res.stderr or ""
      vim.schedule(function()
        if res.code ~= 0 then
          return cb(string.format("curl exited with %s: %s", tostring(res.code), vim.trim(stderr)))
        end
        local body, status = split_status(stdout)
        if not status then
          return cb("could not parse HTTP status from curl output")
        end
        cb(nil, { status = status, body = body })
      end)
    end)
    if not ok then
      return cb("failed to start curl: " .. tostring(started))
    end
    proc = started
    M._running[proc] = true
    return
  end

  -- Fallback for older Neovim without vim.system: synchronous, but the UI is
  -- only blocked for as long as the request takes.
  local stdout = vim.fn.system(cmd)
  local code = vim.v.shell_error
  if code ~= 0 then
    return cb(string.format("curl exited with %d", code))
  end
  local body, status = split_status(stdout)
  if not status then
    return cb("could not parse HTTP status from curl output")
  end
  cb(nil, { status = status, body = body })
end

---Test hook: forget the cached `curl` lookup.
function M._reset()
  M._has_curl = nil
end

return M
