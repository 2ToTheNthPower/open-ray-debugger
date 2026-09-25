-- Headless end-to-end check used by tests/integration/real_ray_cluster.sh:
-- discover a paused Ray task through the dashboard, attach nvim-dap to it,
-- verify what the user sees and continue the task.
--
-- Environment:
--   RAY_DEBUGGER_SCENARIO       breakpoint | actor | post-mortem | job
--   RAY_DEBUGGER_DASHBOARD_URL  dashboard url (default http://127.0.0.1:8265)
--   RAY_DEBUGGER_LOCAL_ROOT     local project root for the `job` scenario
--   NVIM_DAP_PATH               nvim-dap checkout (required)
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h")

vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
if vim.env.NVIM_DAP_PATH and vim.env.NVIM_DAP_PATH ~= "" then
  vim.opt.runtimepath:prepend(vim.fn.fnamemodify(vim.env.NVIM_DAP_PATH, ":p"))
end

local function say(msg)
  io.stdout:write(msg, "\n")
end

local dap = require("dap")
local config = require("ray-debugger.config")
local post_mortem = require("ray-debugger.post_mortem")
local ray_dap = require("ray-debugger.dap")
local state = require("ray-debugger.state")

local scenario = vim.env.RAY_DEBUGGER_SCENARIO or "breakpoint"
local local_root = vim.env.RAY_DEBUGGER_LOCAL_ROOT

dap.defaults.fallback.switchbuf = "never"
config.setup({
  dashboard_url = vim.env.RAY_DEBUGGER_DASHBOARD_URL or "http://127.0.0.1:8265",
  attach = { working_dir = { local_root = local_root } },
})

local function fail(msg)
  io.stderr:write("FAILED [" .. scenario .. "]: " .. msg .. "\n")
  os.exit(1)
end

local function check(condition, msg)
  if not condition then
    fail(msg)
  end
end

local function wait(predicate, ms, msg)
  if not vim.wait(ms, predicate, 50) then
    fail(msg)
  end
end

-- 1. discovery ------------------------------------------------------------
local done, discovery_err, entries = false, nil, nil
state.paused(config.clusters(), function(err, found)
  discovery_err, entries = err, found
  done = true
end)
wait(function()
  return done
end, 20000, "discovery timed out")
check(not discovery_err, "discovery failed: " .. tostring(discovery_err))
check(#entries == 1, string.format("expected 1 paused task, got %d", #entries))
local entry = entries[1]
say("DISCOVERED " .. entry.label)

-- 2. scenario specific setup ---------------------------------------------
local local_breakpoint_line
if scenario == "job" then
  check(entry.working_dir ~= nil, "Ray Job task has no working_dir in its runtime env")
  -- Set a breakpoint in the *local* file; it only hits if the path mapping works.
  local file = local_root .. "/app_task.py"
  for index, line in ipairs(vim.fn.readfile(file)) do
    if line:match("^%s*return z") then
      local_breakpoint_line = index
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.api.nvim_win_set_cursor(0, { local_breakpoint_line, 0 })
  dap.set_breakpoint()
end

-- 3. attach ---------------------------------------------------------------
local stops = {}
dap.listeners.after.event_stopped["ray-real-cluster-test"] = function(session, body)
  stops[#stops + 1] = { session = session, body = body }
end

ray_dap.attach(entry)
wait(function()
  local stop = stops[1]
  return stop ~= nil and stop.session.current_frame ~= nil
end, 30000, "no stopped event from the Ray worker")

local session = stops[1].session
local function current()
  return session.current_frame
end

-- 4. what the user sees ---------------------------------------------------
if scenario == "breakpoint" or scenario == "actor" then
  local expected = scenario == "actor" and "bump" or "square"
  wait(function()
    return current().name == expected
  end, 10000, "did not land on the user frame, got " .. tostring(current().name))
  check(
    current().source.path:match("ray_driver%.py$"),
    "wrong file: " .. tostring(current().source.path)
  )
  if scenario == "actor" then
    check(
      entry.actor_id ~= nil and entry.label:match("%(actor%)"),
      "actor task not labelled: " .. entry.label
    )
  end
elseif scenario == "post-mortem" then
  check(
    stops[1].body.reason == "exception",
    "expected an exception stop, got " .. tostring(stops[1].body.reason)
  )
  if current().name ~= "explode" then
    wait(function()
      return post_mortem.last ~= nil
    end, 15000, "traceback was not recovered")
    local frame = post_mortem.last.info.frames[post_mortem.last.user_index]
    check(frame and frame.name == "explode", "recovered the wrong frame")
    check(
      frame.file:match("ray_driver%.py$"),
      "recovered frame has wrong file: " .. tostring(frame.file)
    )
    check(frame.locals.values == "[1, 2]", "wrong locals: " .. vim.inspect(frame.locals))
    say("RECOVERED " .. frame.name .. " " .. frame.file .. ":" .. frame.line)
  end
elseif scenario == "job" then
  wait(function()
    return current().name == "double"
  end, 10000, "did not land on the user frame")
  local expected = vim.fn.fnamemodify(local_root .. "/app_task.py", ":p")
  check(
    current().source.path == expected,
    "not mapped to the local file: " .. tostring(current().source.path)
  )
  -- continue to the breakpoint set in the local file
  dap.continue()
  wait(function()
    return #stops >= 2 and stops[2].session.current_frame ~= nil
  end, 20000, "local breakpoint was not hit (path mapping to the cluster failed)")
  local frame = stops[2].session.current_frame
  check(frame.source.path == expected, "second stop not mapped: " .. tostring(frame.source.path))
  check(
    frame.line == local_breakpoint_line,
    "stopped on line " .. frame.line .. ", expected " .. local_breakpoint_line
  )
  say("LOCAL BREAKPOINT HIT " .. frame.source.path .. ":" .. frame.line)
end

say(string.format("STOPPED %s:%d", current().source.path, current().line))

-- 5. resume -----------------------------------------------------------------
dap.continue()
vim.wait(3000, function()
  return false
end, 50)
pcall(dap.close)

say("ATTACH_TEST_OK")
os.exit(0)
