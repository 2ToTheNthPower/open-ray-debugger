-- End-to-end test against a real debugpy debuggee that mimics a Ray worker
-- sitting on `breakpoint()`.
--
-- Enable with:
--   RAY_DEBUGGER_DEBUGPY=1 nvim --clean -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local python = vim.env.RAY_DEBUGGER_PYTHON or "python3"

local function skip_reason()
  if vim.env.RAY_DEBUGGER_DEBUGPY ~= "1" then
    return "set RAY_DEBUGGER_DEBUGPY=1 to enable the real debugpy test"
  end
  if not pcall(require, "dap") then
    return "nvim-dap not on the runtimepath (set NVIM_DAP_PATH)"
  end
  local output = vim.fn.system({ python, "-c", "import debugpy" })
  if vim.v.shell_error ~= 0 then
    return "debugpy is not importable by " .. python .. " (" .. vim.trim(output) .. ")"
  end
  return nil
end

local reason = skip_reason()
if reason then
  describe("debugpy end-to-end", function()
    it_skip("attaches to a real debugpy debuggee", reason)
  end)
  return
end

local dap = require("dap")
local ray_dap = require("ray-debugger.dap")

describe("debugpy end-to-end", function()
  it("attaches to a debuggee waiting on breakpoint() and continues it", function()
    dap.defaults.fallback.switchbuf = "never"

    local target = root .. "/tests/integration/ray_debuggee.py"
    local expected_line
    for index, line in ipairs(vim.fn.readfile(target)) do
      if line:match("^%s*breakpoint%(%)%s*$") then
        expected_line = index
      end
    end
    assert_truthy(expected_line, "target script has no breakpoint() line")

    local stdout, stderr = {}, {}
    local port, exit_code
    local job = vim.fn.jobstart({ python, target }, {
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        for _, line in ipairs(data or {}) do
          stdout[#stdout + 1] = line
          local found = line:match("^PORT=(%d+)$")
          if found then
            port = tonumber(found)
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data or {}) do
          stderr[#stderr + 1] = line
        end
      end,
      on_exit = function(_, code)
        exit_code = code
      end,
    })
    assert_truthy(job > 0, "could not start the debuggee")

    local stopped
    dap.listeners.after.event_stopped["ray-debugger-debugpy-test"] = function(session, body)
      stopped = { session = session, body = body }
    end

    local function stderr_text()
      return table.concat(stderr, "\n")
    end

    local ok, err = pcall(function()
      wait_for(function()
        return port ~= nil
      end, 20000, "debuggee never reported its debug port; stderr: " .. stderr_text())

      ray_dap.setup_adapter()
      ray_dap.attach({ host = "127.0.0.1", port = port, label = "debugpy target" })

      wait_for(function()
        return stopped ~= nil
      end, 30000, "no stopped event from debugpy; stderr: " .. stderr_text())

      -- nvim-dap fetches threads/stackTrace asynchronously after `stopped`.
      wait_for(function()
        return stopped.session.current_frame ~= nil
      end, 10000, "nvim-dap never resolved the current frame")

      local frame = stopped.session.current_frame
      assert_truthy(frame, "session has no current frame")
      assert_match("ray_debuggee%.py$", frame.source.path)
      -- pydevd suspends the frame at its next line event, which is either the
      -- `breakpoint()` line or the statement right after it.
      assert_truthy(
        frame.line == expected_line or frame.line == expected_line + 1,
        string.format(
          "stopped on line %d, expected %d or %d",
          frame.line or -1,
          expected_line,
          expected_line + 1
        )
      )

      dap.continue()
      wait_for(function()
        return vim.tbl_contains(stdout, "DONE")
      end, 20000, "debuggee did not finish; stderr: " .. stderr_text())
      wait_for(function()
        return exit_code ~= nil
      end, 10000, "debuggee did not exit")
      assert_eq(0, exit_code, "debuggee failed: " .. stderr_text())
    end)

    pcall(dap.close)
    pcall(function()
      vim.fn.jobstop(job)
    end)
    dap.listeners.after.event_stopped["ray-debugger-debugpy-test"] = nil

    if not ok then
      error(err)
    end
  end)

  it("gives post-mortem access to the failing frame on any debugpy version", function()
    dap.defaults.fallback.switchbuf = "never"
    require("ray-debugger.config").setup({})
    local post_mortem = require("ray-debugger.post_mortem")
    post_mortem.last = nil
    vim.fn.setqflist({}, "r")

    local target = root .. "/tests/integration/ray_post_mortem_debuggee.py"
    local raise_line
    for index, line in ipairs(vim.fn.readfile(target)) do
      if line:match("raise ValueError") then
        raise_line = index
      end
    end

    local stdout, stderr, port = {}, {}, nil
    local job = vim.fn.jobstart({ python, target }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data or {}) do
          stdout[#stdout + 1] = line
          port = port or tonumber(line:match("^PORT=(%d+)$"))
        end
      end,
      on_stderr = function(_, data)
        vim.list_extend(stderr, data or {})
      end,
    })

    local notifications = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      notifications[#notifications + 1] = msg
      real_notify(msg, level)
    end

    local stopped
    dap.listeners.after.event_stopped["ray-debugger-pm-test"] = function(session, body)
      stopped = { session = session, body = body }
    end

    local ok, err = pcall(function()
      wait_for(function()
        return port ~= nil
      end, 20000, "debuggee never reported its port: " .. table.concat(stderr, "\n"))
      ray_dap.attach({ host = "127.0.0.1", port = port, label = "post-mortem target" })

      wait_for(function()
        return stopped ~= nil and stopped.session.current_frame ~= nil
      end, 30000, "no stopped event")
      assert_eq("exception", stopped.body.reason)

      local native = stopped.session.current_frame.name == "explode"
      if not native then
        -- debugpy >= 1.8.6: the plugin recovers the traceback
        wait_for(function()
          return post_mortem.last ~= nil
        end, 15000, "post-mortem traceback was not recovered")
        local info = post_mortem.last.info
        local frame = info.frames[post_mortem.last.user_index]
        assert_eq("ValueError", info.type)
        assert_eq("explode", frame.name)
        assert_eq(raise_line, frame.line)
        assert_eq("[1, 2]", frame.locals.values)
        assert_eq("1", frame.locals.x)

        local qf = vim.fn.getqflist({ title = 1, items = 1 })
        assert_match("ValueError: boom", qf.title)

        -- the REPL can now evaluate in Ray's hook frame, which holds `error`
        local evaluated
        stopped.session:evaluate(
          { expression = "type(error[1]).__name__", context = "repl" },
          function(e, r)
            evaluated = { err = e, result = r and r.result }
          end
        )
        wait_for(function()
          return evaluated ~= nil
        end, 10000)
        assert_eq("'ValueError'", evaluated.result)
      end

      for _, msg in ipairs(notifications) do
        assert_falsy(
          msg:match("[Ee]rror getting exception info"),
          "noisy exceptionInfo error: " .. msg
        )
      end

      dap.continue()
      wait_for(function()
        return vim.tbl_contains(stdout, "DONE")
      end, 20000, "debuggee did not finish")
    end)

    vim.notify = real_notify
    pcall(dap.close)
    pcall(vim.fn.jobstop, job)
    dap.listeners.after.event_stopped["ray-debugger-pm-test"] = nil
    if not ok then
      error(err)
    end
  end)
end)
