local config = require("ray-debugger.config")
local state = require("ray-debugger.state")
local dashboard = require("tests.support.mock_dashboard")

---Run `state.paused` synchronously for tests.
local function run_paused(clusters)
  local done, err, entries, warnings = false, nil, nil, nil
  state.paused(clusters, function(api_err, api_entries, api_warnings)
    err, entries, warnings = api_err, api_entries, api_warnings
    done = true
  end)
  wait_for(function()
    return done
  end, 15000, "state.paused timed out")
  return err, entries, warnings
end

describe("state discovery", function()
  it("lists paused workers and joins the newest running task", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return {
          body = dashboard.envelope({
            {
              worker_id = "w1",
              is_alive = true,
              num_paused_threads = 1,
              debugger_port = 5555,
              ip = "10.0.0.5",
              pid = 100,
            },
            -- alive but not paused
            {
              worker_id = "w2",
              is_alive = true,
              num_paused_threads = 0,
              debugger_port = 6666,
              ip = "10.0.0.6",
              pid = 101,
            },
            -- dead workers are ignored even if they were paused
            {
              worker_id = "w3",
              is_alive = false,
              num_paused_threads = 3,
              debugger_port = 7777,
              ip = "10.0.0.7",
              pid = 102,
            },
          }),
        }
      end,
      ["/api/v0/tasks"] = function(query, handle)
        local worker = handle.query_get(query, "filter_values")
        if worker == "w1" then
          return {
            body = dashboard.envelope({
              {
                task_id = "t-old",
                worker_id = "w1",
                state = "RUNNING",
                func_or_class_name = "old",
                start_time_ms = 1,
              },
              {
                task_id = "t-new",
                worker_id = "w1",
                state = "RUNNING",
                func_or_class_name = "new",
                start_time_ms = 2,
              },
            }),
          }
        end
        return { body = dashboard.envelope({}) }
      end,
    })

    local err, entries = run_paused({ { name = "test", url = mock.url } })

    -- The worker request must ask for detail columns (debugger_port lives there).
    local worker_request
    for _, request in ipairs(mock.requests) do
      if request.path == "/api/v0/workers" then
        worker_request = request
      end
    end
    assert_truthy(worker_request, "no /api/v0/workers request seen")
    assert_eq({ "detail", "1" }, worker_request.query[1])

    mock.stop()

    assert_eq(nil, err)
    assert_eq(1, #entries)
    assert_eq("new", entries[1].func_or_class_name)
    assert_eq("t-new", entries[1].task_id)
    assert_eq("10.0.0.5", entries[1].host)
    assert_eq(5555, entries[1].port)
    assert_eq("w1", entries[1].worker_id)
    assert_eq("RUNNING", entries[1].state)
  end)

  it("uses debugger_port as fallback on clusters without num_paused_threads", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return {
          body = dashboard.envelope({
            { worker_id = "w1", is_alive = true, debugger_port = 4444, ip = "127.0.0.1" },
            { worker_id = "w2", is_alive = true, debugger_port = nil, ip = "127.0.0.1" },
          }),
        }
      end,
      ["/api/v0/tasks"] = function()
        return { body = dashboard.envelope({}) }
      end,
    })

    local err, entries = run_paused({ { name = "test", url = mock.url } })
    mock.stop()

    assert_eq(nil, err)
    assert_eq(1, #entries)
    assert_eq(4444, entries[1].port)
  end)

  it("accepts the flat list shape from older dashboards", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return {
          body = dashboard.envelope({
            {
              worker_id = "w1",
              is_alive = true,
              num_paused_threads = 1,
              debugger_port = 3333,
              ip = "127.0.0.1",
            },
          }, { flat = true }),
        }
      end,
      ["/api/v0/tasks"] = function()
        return { body = dashboard.envelope({}, { flat = true }) }
      end,
    })

    local err, entries = run_paused({ { name = "test", url = mock.url } })
    mock.stop()

    assert_eq(nil, err)
    assert_eq(1, #entries)
    assert_eq(3333, entries[1].port)
  end)

  it("extracts the working_dir of Ray Job tasks and tolerates JSON nulls", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        -- raw JSON so `null` values arrive exactly like Ray sends them
        return {
          body = [[{"result": true, "msg": "", "data": {"result": {"total": 2, "result": [
            {"worker_id": "idle", "is_alive": true, "ip": "10.0.0.1", "debugger_port": null, "num_paused_threads": null},
            {"worker_id": "w1", "is_alive": true, "ip": "10.0.0.1", "pid": 7, "debugger_port": 4040, "num_paused_threads": 1}
          ]}}}]],
        }
      end,
      ["/api/v0/tasks"] = function()
        return {
          body = [[{"result": true, "msg": "", "data": {"result": {"total": 1, "result": [
            {"task_id": "t1", "worker_id": "w1", "state": "RUNNING", "name": "double",
             "func_or_class_name": "double", "actor_id": null, "error_type": null,
             "is_debugger_paused": null, "start_time_ms": 5,
             "runtime_env_info": {"serialized_runtime_env": "{\"working_dir\": \"gcs://_ray_pkg_abc.zip\"}"}}
          ]}}}]],
        }
      end,
    })

    local err, entries = run_paused({ { name = "test", url = mock.url } })
    mock.stop()

    assert_eq(nil, err)
    assert_eq(1, #entries)
    assert_eq("gcs://_ray_pkg_abc.zip", entries[1].working_dir)
    assert_eq(nil, entries[1].is_debugger_paused)
    assert_eq(nil, entries[1].actor_id)
    assert_eq(nil, entries[1].error_type)
    assert_eq("[test] double RUNNING @ 10.0.0.1:4040", entries[1].label)
  end)

  it("ignores malformed runtime env payloads", function()
    assert_eq(nil, state.runtime_env_working_dir(nil))
    assert_eq(
      nil,
      state.runtime_env_working_dir({ runtime_env_info = { serialized_runtime_env = "{" } })
    )
    assert_eq(
      nil,
      state.runtime_env_working_dir({ runtime_env_info = { serialized_runtime_env = "{}" } })
    )
  end)

  it("prefers tasks that are explicitly paused by the debugger", function()
    local task = state.pick_task({
      { task_id = "running", state = "RUNNING", start_time_ms = 100 },
      { task_id = "paused", state = "FAILED", is_debugger_paused = true, start_time_ms = 1 },
    })
    assert_eq("paused", task.task_id)
  end)

  it("falls back to the newest task when nothing is running", function()
    local task = state.pick_task({
      { task_id = "older", state = "FAILED", start_time_ms = 1 },
      { task_id = "newer", state = "FAILED", start_time_ms = 2 },
    })
    assert_eq("newer", task.task_id)
  end)

  it("surfaces dashboard HTTP errors", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return { status = 500, body = '{"result":false,"msg":"boom","data":null}' }
      end,
    })
    local err = run_paused({ { name = "test", url = mock.url } })
    mock.stop()
    assert_match("HTTP 500", err)
  end)

  it("surfaces invalid JSON", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return { body = "definitely not json" }
      end,
    })
    local err = run_paused({ { name = "test", url = mock.url } })
    mock.stop()
    assert_match("invalid JSON", err)
  end)

  it("merges clusters and warns when one is unreachable", function()
    local good = dashboard.start({
      ["/api/v0/workers"] = function()
        return {
          body = dashboard.envelope({
            {
              worker_id = "w1",
              is_alive = true,
              num_paused_threads = 1,
              debugger_port = 1,
              ip = "127.0.0.1",
            },
          }),
        }
      end,
      ["/api/v0/tasks"] = function()
        return { body = dashboard.envelope({}) }
      end,
    })
    local dead = dashboard.start({})
    local dead_url = dead.url
    dead.stop()

    local err, entries, warnings = run_paused({
      { name = "good", url = good.url },
      { name = "dead", url = dead_url },
    })
    good.stop()

    assert_eq(nil, err)
    assert_eq(1, #entries)
    assert_eq(1, #warnings)
    assert_match("dead", warnings[1])
  end)

  it("fails when every cluster is unreachable", function()
    local dead = dashboard.start({})
    local dead_url = dead.url
    dead.stop()

    local err = run_paused({ { name = "dead", url = dead_url } })
    assert_truthy(err)
    assert_match("dead", err)
  end)
end)

config.setup({})
