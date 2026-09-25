-- Headless end-to-end check used by tests/integration/real_ray_cluster.sh:
-- discover a paused Ray task through the dashboard, attach nvim-dap to it,
-- verify the stopped frame and continue the task.
--
-- Environment:
--   RAY_DEBUGGER_DASHBOARD_URL  dashboard url (default http://127.0.0.1:8265)
--   NVIM_DAP_PATH               nvim-dap checkout (required)
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h")

vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
if vim.env.NVIM_DAP_PATH and vim.env.NVIM_DAP_PATH ~= "" then
  vim.opt.runtimepath:prepend(vim.fn.fnamemodify(vim.env.NVIM_DAP_PATH, ":p"))
end

local dap = require("dap")
local config = require("ray-debugger.config")
local ray_dap = require("ray-debugger.dap")
local state = require("ray-debugger.state")

dap.defaults.fallback.switchbuf = "never"

config.setup({
  dashboard_url = vim.env.RAY_DEBUGGER_DASHBOARD_URL or "http://127.0.0.1:8265",
})

local done, discovery_err, entries = false, nil, nil
state.paused(config.clusters(), function(err, found)
  discovery_err, entries = err, found
  done = true
end)
vim.wait(20000, function()
  return done
end, 50)

assert(not discovery_err, "discovery failed: " .. tostring(discovery_err))
assert(#entries == 1, string.format("expected 1 paused task, got %d", #entries))
print("DISCOVERED " .. entries[1].label)

local stopped
dap.listeners.after.event_stopped["ray-real-cluster-test"] = function(session, body)
  stopped = { session = session, body = body }
end

ray_dap.attach(entries[1])
-- The plugin skips Ray's internal frames, so wait for the user frame.
vim.wait(30000, function()
  return stopped ~= nil
    and stopped.session.current_frame ~= nil
    and stopped.session.current_frame.source.path:match("ray_driver%.py$")
end, 50)

assert(stopped, "no stopped event from the Ray worker")
local frame = stopped.session.current_frame
print(string.format("STOPPED %s:%d", frame.source.path, frame.line))
assert(
  frame.source.path:match("ray_driver%.py$"),
  "stopped in the wrong file: " .. tostring(frame.source.path)
)

dap.continue()
vim.wait(5000, function()
  return false
end, 50)
pcall(dap.close)

print("ATTACH_TEST_OK")
os.exit(0)
