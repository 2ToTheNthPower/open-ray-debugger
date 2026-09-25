-- Tests for the nvim-dap adapter plumbing using a fake `dap` module.
describe("dap module", function()
  local real_dap = package.loaded["dap"]
  local fake_dap = {
    adapters = {},
    listeners = { before = {}, after = { event_stopped = {} } },
  }
  fake_dap.run = function(cfg)
    fake_dap.ran = cfg
  end
  package.loaded["dap"] = fake_dap
  package.loaded["ray-debugger.dap"] = nil

  local rdap = require("ray-debugger.dap")

  it("registers a `server` adapter that speaks DAP to debugpy", function()
    local dap = rdap.setup_adapter()
    assert_eq(fake_dap, dap)
    assert_eq("function", type(fake_dap.adapters.ray))
    assert_eq("function", type(fake_dap.listeners.after.event_stopped["ray-debugger"]))

    local adapter
    fake_dap.adapters.ray(function(a)
      adapter = a
    end, { host = "10.1.2.3", port = 4242 })

    assert_eq("server", adapter.type)
    assert_eq("python", adapter.id) -- adapterID sent in `initialize`
    assert_eq("10.1.2.3", adapter.host)
    assert_eq(4242, adapter.port)
    assert_eq("python", adapter.options.source_filetype)
  end)

  it("builds an attach run configuration", function()
    local args = rdap.run_config({ host = "h", port = 1234, label = "f() RUNNING @ h:1234" })
    assert_eq("ray", args.type)
    assert_eq("attach", args.request)
    assert_eq("h", args.host)
    assert_eq(1234, args.port)
    assert_eq(false, args.justMyCode)
    assert_match("f%(%)", args.name)
  end)

  it("passes path mappings and extra args through", function()
    local args = rdap.run_config({ host = "h", port = 1, label = "x" }, {
      path_mappings = { { localRoot = "/local", remoteRoot = "/remote" } },
      extra_args = { showReturnValue = true },
    })
    assert_eq("/local", args.pathMappings[1].localRoot)
    assert_eq(true, args.showReturnValue)
  end)

  it("calls dap.run when attaching", function()
    local args = rdap.attach({ host = "h", port = 99, label = "l" })
    assert_eq(args, fake_dap.ran)
  end)

  it("refuses to attach without a debugger port", function()
    local args, err = rdap.attach({ host = "h", port = 0, label = "l" })
    assert_eq(nil, args)
    assert_match("no debugger port", err)
  end)

  it("recognizes Ray and debugger internal frames", function()
    assert_truthy(
      rdap.is_internal_frame({ source = { path = "/venv/site-packages/ray/util/rpdb.py" } })
    )
    assert_truthy(
      rdap.is_internal_frame({ source = { path = "/venv/site-packages/ray/util/debugpy.py" } })
    )
    assert_truthy(rdap.is_internal_frame({
      source = {
        path = "/venv/site-packages/debugpy/_vendored/pydevd/_pydevd_bundle/pydevd_comm.py",
      },
    }))
    assert_falsy(rdap.is_internal_frame({ source = { path = "/home/me/app.py" } }))
    assert_falsy(
      rdap.is_internal_frame({ source = { path = "/venv/site-packages/ray/train/trainer.py" } })
    )
    assert_falsy(rdap.is_internal_frame(nil))
  end)

  ---Build a fake nvim-dap session with a small call stack.
  local function fake_session(frames, config_type)
    local session = {
      config = { type = config_type or "ray" },
      threads = { [1] = { frames = frames } },
      current_frame = frames[1],
      moves = 0,
    }
    session._frame_delta = function(self, delta)
      for index, frame in ipairs(self.threads[1].frames) do
        if frame.id == self.current_frame.id then
          self.current_frame = self.threads[1].frames[index + delta] or self.current_frame
          self.moves = self.moves + 1
          return
        end
      end
    end
    return session
  end

  it("walks up to the user frame when Ray plumbing is on top", function()
    local session = fake_session({
      { id = 1, source = { path = "/venv/site-packages/ray/util/rpdb.py" } },
      { id = 2, source = { path = "/venv/site-packages/ray/util/debugpy.py" } },
      { id = 3, source = { path = "/home/me/app.py" } },
      { id = 4, source = { path = "/venv/site-packages/ray/_private/worker.py" } },
    })

    rdap._on_stopped(session, { reason = "breakpoint", threadId = 1 })

    assert_eq(3, session.current_frame.id)
    assert_eq(2, session.moves)
  end)

  it("leaves step stops alone", function()
    local session = fake_session({
      { id = 1, source = { path = "/venv/site-packages/ray/util/rpdb.py" } },
      { id = 2, source = { path = "/home/me/app.py" } },
    })

    rdap._on_stopped(session, { reason = "step", threadId = 1 })

    assert_eq(1, session.current_frame.id)
    assert_eq(0, session.moves)
  end)

  it("leaves sessions from other adapters alone", function()
    local session = fake_session({
      { id = 1, source = { path = "/venv/site-packages/ray/util/rpdb.py" } },
      { id = 2, source = { path = "/home/me/app.py" } },
    }, "python")

    rdap._on_stopped(session, { reason = "breakpoint", threadId = 1 })

    assert_eq(1, session.current_frame.id)
    assert_eq(0, session.moves)
  end)

  it("maps working_dir tasks to the local project (remoteRoot = '.')", function()
    local args = rdap.run_config({
      host = "h",
      port = 1,
      label = "x",
      working_dir = "gcs://_ray_pkg_abc.zip",
    }, {
      path_mappings = { { localRoot = "/a", remoteRoot = "/b" } },
      working_dir = { local_root = "/tmp/my-project/" },
    })
    assert_eq({ localRoot = "/a", remoteRoot = "/b" }, args.pathMappings[1])
    assert_eq({ localRoot = "/tmp/my-project", remoteRoot = "." }, args.pathMappings[2])
  end)

  it("defaults the working_dir local root to Neovim's cwd", function()
    local args =
      rdap.run_config({ host = "h", port = 1, label = "x", working_dir = "gcs://_ray_pkg_abc.zip" })
    local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
    assert_eq({ { localRoot = cwd, remoteRoot = "." } }, args.pathMappings)
  end)

  it("resolves a working_dir local root function per entry", function()
    local args = rdap.run_config(
      { host = "h", port = 1, label = "x", working_dir = "gcs://pkg.zip", job_id = "02" },
      {
        working_dir = {
          local_root = function(entry)
            return "/jobs/" .. entry.job_id
          end,
        },
      }
    )
    assert_eq("/jobs/02", args.pathMappings[1].localRoot)
  end)

  it("skips the working_dir mapping when disabled or not needed", function()
    local disabled = rdap.run_config(
      { host = "h", port = 1, label = "x", working_dir = "gcs://pkg.zip" },
      { working_dir = { enabled = false } }
    )
    assert_eq(nil, disabled.pathMappings)
    local plain = rdap.run_config({ host = "h", port = 1, label = "x" })
    assert_eq(nil, plain.pathMappings)
  end)

  it("suppresses exceptionInfo for Ray's broken post-mortem stack", function()
    local session =
      { config = { type = "ray" }, capabilities = { supportsExceptionInfoRequest = true } }
    rdap._before_stack_trace(session, nil, {
      stackFrames = { { name = "helper" }, { name = "_debugpy_excepthook" } },
    })
    assert_eq(false, session.capabilities.supportsExceptionInfoRequest)

    local healthy =
      { config = { type = "ray" }, capabilities = { supportsExceptionInfoRequest = true } }
    rdap._before_stack_trace(healthy, nil, { stackFrames = { { name = "explode" } } })
    assert_eq(true, healthy.capabilities.supportsExceptionInfoRequest)

    local other =
      { config = { type = "python" }, capabilities = { supportsExceptionInfoRequest = true } }
    rdap._before_stack_trace(other, nil, { stackFrames = { { name = "_debugpy_excepthook" } } })
    assert_eq(true, other.capabilities.supportsExceptionInfoRequest)
  end)

  it("runs post-mortem recovery on exception stops with Ray's excepthook frame", function()
    local post_mortem = require("ray-debugger.post_mortem")
    local real_run = post_mortem.run
    local ran_with
    post_mortem.run = function(_, frame)
      ran_with = frame
    end

    local session = fake_session({
      { id = 1, name = "helper", source = { path = "/usr/lib/python3.12/contextlib.py" } },
      {
        id = 2,
        name = "_debugpy_excepthook",
        source = { path = "/venv/site-packages/ray/util/debugpy.py" },
      },
    })
    rdap._on_stopped(session, { reason = "exception", threadId = 1 })
    post_mortem.run = real_run

    assert_eq(2, ran_with.id)
    -- exception stops never move frames
    assert_eq(0, session.moves)
  end)

  it("does not move when every frame is plumbing", function()
    local session = fake_session({
      { id = 1, source = { path = "/venv/site-packages/ray/util/rpdb.py" } },
      { id = 2, source = { path = "/venv/site-packages/ray/util/debugpy.py" } },
    })
    rdap._on_stopped(session, { reason = "breakpoint", threadId = 1 })
    assert_eq(0, session.moves)
  end)

  -- Restore the environment for the specs that follow.
  package.loaded["dap"] = real_dap
  package.loaded["ray-debugger.dap"] = nil
end)
