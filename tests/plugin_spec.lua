-- Commands, :checkhealth and the HTTP layer.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local config = require("ray-debugger.config")
local dashboard = require("tests.support.mock_dashboard")
local http = require("ray-debugger.http")
local state = require("ray-debugger.state")

describe("user commands", function()
  vim.g.loaded_ray_debugger = nil
  dofile(root .. "/plugin/ray-debugger.lua")

  it("defines every command", function()
    for _, name in ipairs({
      "RayDebug",
      "RayDebugAttach",
      "RayDebugRefresh",
      "RayDebugPostMortem",
      "RayDebugWatch",
    }) do
      assert_eq(2, vim.fn.exists(":" .. name), name .. " is not defined")
    end
  end)

  it("completes :RayDebugWatch arguments", function()
    assert_eq({ "on", "off" }, vim.fn.getcompletion("RayDebugWatch ", "cmdline"))
  end)

  it("is idempotent", function()
    -- a second source must not error or redefine anything
    dofile(root .. "/plugin/ray-debugger.lua")
    assert_eq(1, vim.g.loaded_ray_debugger)
  end)
end)

describe("http", function()
  it("sends configured headers and keeps trailing newlines in bodies", function()
    local mock = dashboard.start({
      ["/api/v0/workers"] = function()
        return { body = dashboard.envelope({}) .. "\n" }
      end,
    })
    config.setup({})

    local done, err, data = false, nil, nil
    state.api_get(
      { name = "auth", url = mock.url, headers = { Authorization = "Bearer secret" } },
      "/api/v0/workers",
      nil,
      function(e, d)
        done, err, data = true, e, d
      end
    )
    wait_for(function()
      return done
    end, 10000, "request never completed")
    mock.stop()

    assert_eq(nil, err)
    assert_truthy(data)
    assert_eq("Bearer secret", mock.requests[1].headers.authorization)
    assert_eq("application/json", mock.requests[1].headers.accept)
  end)

  it("fails cleanly when curl is missing", function()
    http._has_curl = false
    local got
    http.get("http://127.0.0.1:1", {}, function(e)
      got = e
    end)
    http._reset()
    assert_match("curl", got)
  end)

  it("releases process references after completion", function()
    local mock = dashboard.start({
      ["/x"] = function()
        return { body = "{}" }
      end,
    })
    local done = false
    http.get(mock.url .. "/x", { timeout_ms = 2000 }, function()
      done = true
    end)
    wait_for(function()
      return done
    end, 10000)
    mock.stop()
    assert_eq(nil, next(http._running))
  end)
end)

describe(":checkhealth", function()
  ---Replace vim.health with a recorder for the duration of `fn`.
  local function record_health(fn)
    local real = vim.health
    local calls = {}
    local recorder = {}
    for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
      recorder[kind] = function(msg)
        calls[#calls + 1] = { kind = kind, msg = msg }
      end
    end
    rawset(vim, "health", recorder)
    local ok, err = pcall(fn)
    rawset(vim, "health", real)
    if not ok then
      error(err)
    end
    return calls
  end

  local function find(calls, kind, pattern)
    for _, call in ipairs(calls) do
      if call.kind == kind and call.msg:match(pattern) then
        return call
      end
    end
    return nil
  end

  it("reports reachable clusters and their paused workers", function()
    local mock = dashboard.start({
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
            {
              worker_id = "w2",
              is_alive = true,
              num_paused_threads = 0,
              debugger_port = 2,
              ip = "127.0.0.1",
            },
          }),
        }
      end,
    })
    config.setup({ dashboard_url = mock.url })
    local calls = record_health(function()
      require("ray-debugger.health").check()
    end)
    mock.stop()

    assert_truthy(find(calls, "ok", "`curl` is available"))
    assert_truthy(find(calls, "ok", "2 worker%(s%), 1 paused"), vim.inspect(calls))
  end)

  it("reports unreachable clusters as errors", function()
    local dead = dashboard.start({})
    local url = dead.url
    dead.stop()
    config.setup({ dashboard_url = url })
    local calls = record_health(function()
      require("ray-debugger.health").check()
    end)
    assert_truthy(find(calls, "error", "default"), vim.inspect(calls))
  end)

  config.setup({})
end)
