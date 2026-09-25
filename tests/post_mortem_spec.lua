-- Tests for post-mortem traceback recovery (debugpy >= 1.8.6 workaround).
local config = require("ray-debugger.config")
local post_mortem = require("ray-debugger.post_mortem")

---Python repr() of a str, the way debugpy returns evaluate results.
local function python_repr(value)
  return "'" .. value:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local sample = {
  type = "ValueError",
  message = "boom: [1, 2] 'quoted'",
  cwd = "/tmp/ray/session_x/runtime_resources/working_dir_files/_ray_pkg_abc",
  frames = {
    { file = "python/ray/_raylet.pyx", line = 2200, name = "execute_task", locals = {} },
    {
      file = "/tmp/ray/session_x/runtime_resources/working_dir_files/_ray_pkg_abc/app.py",
      line = 12,
      name = "explode",
      locals = { values = "[1, 2]", x = "1" },
    },
  },
}

describe("post-mortem recovery", function()
  config.setup({})

  it("decodes debugpy's repr of a string", function()
    assert_eq(
      [[{"a": "it's \"x\" \\ y"}]],
      post_mortem.decode_python_str(python_repr([[{"a": "it's \"x\" \\ y"}]]))
    )
    assert_eq("plain", post_mortem.decode_python_str("plain"))
  end)

  it("parses the recovered traceback JSON", function()
    local info = post_mortem.parse(python_repr(vim.json.encode(sample)))
    assert_eq("ValueError", info.type)
    assert_eq("boom: [1, 2] 'quoted'", info.message)
    assert_eq(2, #info.frames)
    local _, err = post_mortem.parse("'not json'")
    assert_match("could not parse", err)
  end)

  it("maps remote paths, including remoteRoot = '.' (worker cwd)", function()
    local mappings = {
      { localRoot = "/home/me/other", remoteRoot = "/srv/other" },
      { localRoot = "/home/me/proj/", remoteRoot = "." },
    }
    assert_eq(
      "/home/me/proj/app.py",
      post_mortem.map_path(sample.frames[2].file, mappings, sample.cwd)
    )
    assert_eq("/home/me/other/x.py", post_mortem.map_path("/srv/other/x.py", mappings, sample.cwd))
    assert_eq("/elsewhere/y.py", post_mortem.map_path("/elsewhere/y.py", mappings, sample.cwd))
    -- A shared prefix that is not a path component must not be mapped.
    assert_eq(
      "/srv/otherthing/z.py",
      post_mortem.map_path("/srv/otherthing/z.py", mappings, sample.cwd)
    )
  end)

  it("picks the innermost user frame, skipping Cython and Ray frames", function()
    local frames = {
      { file = "/app/main.py" },
      { file = "python/ray/_raylet.pyx" },
      { file = "/app/task.py" },
      { file = "/venv/site-packages/ray/util/debugpy.py" },
    }
    assert_eq(3, post_mortem.user_frame_index(frames))
    assert_eq(nil, post_mortem.user_frame_index({ { file = "python/ray/_raylet.pyx" } }))
  end)

  it("formats a report with the failing frame's locals", function()
    local lines = post_mortem.format_report(sample, 2)
    assert_match("^Ray post%-mortem: ValueError: boom", lines[1])
    local text = table.concat(lines, "\n")
    assert_match("Locals of explode%(%)", text)
    assert_match("values = %[1, 2%]", text)
    assert_match("x = 1", text)
  end)

  it("finds Ray's excepthook frame", function()
    local frame =
      post_mortem.find_hook_frame({ { name = "helper" }, { name = "_debugpy_excepthook", id = 7 } })
    assert_eq(7, frame.id)
    assert_eq(nil, post_mortem.find_hook_frame({ { name = "explode" } }))
  end)

  it("recovers through DAP evaluate and fills the quickfix list", function()
    local local_file = vim.fn.tempname() .. ".py"
    vim.fn.writefile({ "x = 1" }, local_file)
    local info = vim.deepcopy(sample)
    info.frames[2].file = local_file

    local evaluated
    local session = {
      config = { type = "ray" },
      evaluate = function(_, args, cb)
        evaluated = args
        cb(nil, { result = python_repr(vim.json.encode(info)) })
      end,
    }
    local notified = {}
    local real_notify = vim.notify
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end

    local done, recovered
    post_mortem.run(session, { id = 42, name = "_debugpy_excepthook" }, function(err, result)
      done, recovered = true, result
      assert_eq(nil, err)
    end)
    vim.notify = real_notify

    assert_truthy(done)
    assert_eq(42, evaluated.frameId)
    assert_match("walk_tb", evaluated.expression)
    assert_eq("ValueError", recovered.type)

    local qf = vim.fn.getqflist({ title = 1, items = 1 })
    assert_match("ValueError", qf.title)
    assert_eq(2, #qf.items)
    assert_eq(12, qf.items[2].lnum)
    -- jumped to the failing line of the (readable) user file
    assert_eq(
      vim.fn.fnamemodify(local_file, ":p"),
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
    )
    assert_match("post%-mortem ValueError", notified[1])
  end)

  it("reports evaluate failures without raising", function()
    local session = {
      evaluate = function(_, _, cb)
        cb({ message = "frame gone" })
      end,
    }
    local real_notify = vim.notify
    vim.notify = function() end
    local got
    post_mortem.run(session, { id = 1 }, function(err)
      got = err
    end)
    vim.notify = real_notify
    assert_match("frame gone", got)
  end)
end)
