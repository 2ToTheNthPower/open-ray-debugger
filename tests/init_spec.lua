-- End-to-end test of the public API: discovery through the dashboard,
-- the picker, and the hand-off to the DAP adapter.
describe("plugin API", function()
  local real_dap = package.loaded["dap"]
  local real_notify = vim.notify

  local fake_dap = { adapters = {} }
  fake_dap.run = function(cfg)
    fake_dap.ran = cfg
  end

  package.loaded["dap"] = fake_dap
  package.loaded["ray-debugger.dap"] = nil
  package.loaded["ray-debugger"] = nil

  local dashboard = require("tests.support.mock_dashboard")
  local ray_debugger = require("ray-debugger")

  local function start_paused_cluster()
    return dashboard.start({
      ["/api/v0/workers"] = function()
        return {
          body = dashboard.envelope({
            {
              worker_id = "w1",
              is_alive = true,
              num_paused_threads = 1,
              debugger_port = 5555,
              ip = "127.0.0.1",
              pid = 42,
            },
          }),
        }
      end,
      ["/api/v0/tasks"] = function()
        return {
          body = dashboard.envelope({
            {
              task_id = "t1",
              worker_id = "w1",
              state = "RUNNING",
              func_or_class_name = "square",
              start_time_ms = 1,
            },
          }),
        }
      end,
    })
  end

  it("lists paused tasks, shows the picker and attaches", function()
    local mock = start_paused_cluster()
    local picked

    ray_debugger.setup({
      dashboard_url = mock.url,
      picker = function(entries, on_choice)
        picked = entries
        on_choice(entries[1])
      end,
    })

    ray_debugger.pick()
    wait_for(function()
      return fake_dap.ran ~= nil
    end, 15000, "attach never happened")

    mock.stop()

    assert_eq(1, #picked)
    assert_eq("square", picked[1].func_or_class_name)
    assert_eq(5555, picked[1].port)
    assert_eq(1, ray_debugger.paused_count())
    assert_eq("⏸ 1", ray_debugger.status())

    assert_eq("ray", fake_dap.ran.type)
    assert_eq("127.0.0.1", fake_dap.ran.host)
    assert_eq(5555, fake_dap.ran.port)
    assert_eq("attach", fake_dap.ran.request)
  end)

  it("notifies when nothing is paused", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return { body = dashboard.envelope({}) }
      end,
    })

    local notifications = {}
    vim.notify = function(msg)
      notifications[#notifications + 1] = msg
    end

    ray_debugger.setup({ dashboard_url = mock.url })
    ray_debugger.pick()
    wait_for(function()
      return #notifications > 0
    end, 15000, "no notification for an empty cluster")

    mock.stop()
    vim.notify = real_notify

    assert_match("no paused Ray tasks", notifications[1])
  end)

  it("attaches to host:port directly", function()
    fake_dap.ran = nil
    ray_debugger.attach_address("10.0.0.9:1234")
    assert_eq("10.0.0.9", fake_dap.ran.host)
    assert_eq(1234, fake_dap.ran.port)
  end)

  -- Restore the environment for the specs that follow.
  package.loaded["dap"] = real_dap
  package.loaded["ray-debugger.dap"] = nil
  package.loaded["ray-debugger"] = nil
  vim.notify = real_notify
end)
