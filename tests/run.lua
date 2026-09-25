-- Minimal, dependency-free test runner for ray-debugger.nvim.
--
--   nvim --clean -l tests/run.lua
--
-- Optional environment variables:
--   NVIM_DAP_PATH       Path to an nvim-dap checkout (enables nvim-dap tests)
--   RAY_DEBUGGER_DEBUGPY=1  Enable the real debugpy end-to-end test
--   RAY_DEBUGGER_PYTHON Python interpreter used for the debugpy test
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")

vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

if vim.env.NVIM_DAP_PATH and vim.env.NVIM_DAP_PATH ~= "" then
  vim.opt.runtimepath:prepend(vim.fn.fnamemodify(vim.env.NVIM_DAP_PATH, ":p"))
end

local results = { passed = 0, failed = 0, skipped = 0 }
local failures = {}
local current_suite = "<top level>"
local current_test = "<none>"

function _G.describe(name, fn)
  local previous = current_suite
  current_suite = name
  local ok, err = xpcall(fn, debug.traceback)
  current_suite = previous
  if not ok then
    results.failed = results.failed + 1
    failures[#failures + 1] = {
      suite = name,
      test = "<suite>",
      err = err,
    }
    io.write("FAIL " .. name .. " :: <suite setup>\n")
  end
end

function _G.it(name, fn)
  current_test = name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.passed = results.passed + 1
    io.write("ok   " .. current_suite .. " :: " .. name .. "\n")
  else
    results.failed = results.failed + 1
    failures[#failures + 1] = {
      suite = current_suite,
      test = name,
      err = err,
    }
    io.write("FAIL " .. current_suite .. " :: " .. name .. "\n")
  end
end

function _G.it_skip(name, reason)
  results.skipped = results.skipped + 1
  io.write("SKIP " .. current_suite .. " :: " .. name .. " (" .. (reason or "") .. ")\n")
end

function _G.fail(msg)
  error(msg, 2)
end

function _G.assert_truthy(value, msg)
  if not value then
    error((msg or "expected a truthy value") .. ", got: " .. vim.inspect(value), 2)
  end
end

function _G.assert_falsy(value, msg)
  if value then
    error((msg or "expected a falsy value") .. ", got: " .. vim.inspect(value), 2)
  end
end

function _G.assert_eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format(
        "%s\n  expected: %s\n  actual:   %s",
        msg or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function _G.assert_match(pattern, value, msg)
  if type(value) ~= "string" or not value:match(pattern) then
    error(
      string.format(
        "%s\n  pattern: %s\n  value:   %s",
        msg or "no match",
        pattern,
        vim.inspect(value)
      ),
      2
    )
  end
end

---Wait until `predicate` is true or the timeout expires. Errors on timeout.
---@param predicate fun(): boolean
---@param timeout_ms? integer
---@param msg? string
function _G.wait_for(predicate, timeout_ms, msg)
  local ok = vim.wait(timeout_ms or 10000, predicate, 20)
  if not ok then
    error((msg or "timed out waiting for condition"), 2)
  end
end

local specs = {
  "tests/util_spec.lua",
  "tests/config_spec.lua",
  "tests/state_spec.lua",
  "tests/dap_spec.lua",
  "tests/post_mortem_spec.lua",
  "tests/init_spec.lua",
  "tests/plugin_spec.lua",
  "tests/nvim_dap_spec.lua",
  "tests/debugpy_spec.lua",
}

for _, spec in ipairs(specs) do
  local path = root .. "/" .. spec
  local chunk, load_err = loadfile(path)
  if not chunk then
    results.failed = results.failed + 1
    failures[#failures + 1] = { suite = spec, test = "<load>", err = load_err }
    io.write("FAIL " .. spec .. " :: <load>\n" .. tostring(load_err) .. "\n")
  else
    local ok, err = xpcall(chunk, debug.traceback)
    if not ok then
      results.failed = results.failed + 1
      failures[#failures + 1] = { suite = spec, test = "<run>", err = err }
      io.write("FAIL " .. spec .. " :: <run>\n" .. tostring(err) .. "\n")
    end
  end
end

io.write("\n")
for _, failure in ipairs(failures) do
  io.write(
    string.format("--- %s :: %s ---\n%s\n\n", failure.suite, failure.test, tostring(failure.err))
  )
end

io.write(
  string.format(
    "passed: %d, failed: %d, skipped: %d\n",
    results.passed,
    results.failed,
    results.skipped
  )
)

os.exit(results.failed == 0 and 0 or 1)
