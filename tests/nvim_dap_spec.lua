-- Integration test: our adapter + real nvim-dap against a mock DAP server.
local has_dap = pcall(require, "dap")

if not has_dap then
  describe("nvim-dap integration", function()
    it_skip(
      "attaches to a mock DAP server",
      "nvim-dap not on the runtimepath (set NVIM_DAP_PATH=/path/to/nvim-dap)"
    )
  end)
  return
end

local dap = require("dap")
local mock_dap = require("tests.support.mock_dap")
local ray_dap = require("ray-debugger.dap")

describe("nvim-dap integration", function()
  it("attaches through the ray adapter and receives a stopped event", function()
    local spec_path = debug.getinfo(1, "S").source:sub(2)
    dap.defaults.fallback.switchbuf = "never"

    local mock = mock_dap.start({ source_path = spec_path, line = 3 })
    ray_dap.setup_adapter()

    local stopped
    dap.listeners.after.event_stopped["ray-debugger-test"] = function(session, body)
      stopped = { session = session, body = body }
    end

    local ok, err = pcall(function()
      local args = ray_dap.attach({ host = "127.0.0.1", port = mock.port, label = "mock task" })
      assert_truthy(args, "attach returned no configuration")

      wait_for(function()
        return stopped ~= nil
      end, 5000, "no stopped event from the mock adapter")

      assert_eq("breakpoint", stopped.body.reason)

      local commands = {}
      for _, request in ipairs(mock.requests) do
        commands[request.command] = true
        if request.command == "initialize" then
          -- debugpy expects the Python adapter id
          assert_eq("python", request.arguments.adapterID)
        end
      end
      assert_truthy(commands.initialize, "no initialize request")
      assert_truthy(commands.attach, "no attach request")
      assert_truthy(commands.configurationDone, "no configurationDone request")
    end)

    pcall(dap.close)
    pcall(mock.stop)
    dap.listeners.after.event_stopped["ray-debugger-test"] = nil

    if not ok then
      error(err)
    end
  end)
end)
