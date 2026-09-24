-- Tests for the nvim-dap adapter plumbing using a fake `dap` module.
describe("dap module", function()
  local real_dap = package.loaded["dap"]
  local fake_dap = { adapters = {} }
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

  package.loaded["dap"] = real_dap
  package.loaded["ray-debugger.dap"] = nil
end)
