local config = require("ray-debugger.config")

describe("config", function()
  it("defaults to the local dashboard", function()
    config.setup({})
    local clusters = config.clusters()
    assert_eq(1, #clusters)
    assert_eq("default", clusters[1].name)
    assert_eq("http://127.0.0.1:8265", clusters[1].url)
  end)

  it("accepts a custom dashboard url", function()
    config.setup({ dashboard_url = "http://ray-head:8265/" })
    assert_eq("http://ray-head:8265/", config.clusters()[1].url)
  end)

  it("normalizes multiple clusters, including string shorthands", function()
    config.setup({
      clusters = {
        "http://a:8265",
        { name = "k8s", url = "http://b:8265", dap_host = "10.0.0.1" },
      },
    })
    local clusters = config.clusters()
    assert_eq(2, #clusters)
    assert_eq("cluster-1", clusters[1].name)
    assert_eq("http://a:8265", clusters[1].url)
    assert_eq("k8s", clusters[2].name)
    assert_eq("10.0.0.1", clusters[2].dap_host)
  end)

  it("merges nested attach options", function()
    config.setup({
      attach = {
        just_my_code = true,
        extra_args = { foo = "bar" },
      },
    })
    assert_eq(true, config.options.attach.just_my_code)
    assert_eq("bar", config.options.attach.extra_args.foo)
    -- untouched defaults survive the merge
    assert_eq(3, config.options.attach.disconnect_timeout_sec)
  end)

  it("rejects clusters without a url", function()
    local ok = pcall(config.setup, { clusters = { { name = "broken" } } })
    assert_falsy(ok, "setup should reject a cluster without a url")
  end)

  it("resets options on every setup call", function()
    config.setup({ dashboard_url = "http://one:8265" })
    config.setup({})
    assert_eq("http://127.0.0.1:8265", config.clusters()[1].url)
  end)
end)

-- Leave the module in a sane state for the specs that run after this one.
config.setup({})
