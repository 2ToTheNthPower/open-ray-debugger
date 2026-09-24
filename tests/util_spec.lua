local util = require("ray-debugger.util")

describe("util", function()
  it("joins urls without duplicate slashes", function()
    assert_eq("http://x:8265/api/v0/workers", util.join_url("http://x:8265", "/api/v0/workers"))
    assert_eq("http://x:8265/api/v0/workers", util.join_url("http://x:8265/", "api/v0/workers"))
  end)

  it("percent-encodes query components", function()
    assert_eq("a%20b%2Fc%3Dd", util.urlencode("a b/c=d"))
    assert_eq("True", util.urlencode("True"))
  end)

  it("encodes repeated query keys", function()
    local encoded = util.encode_query({
      { "filter_keys", "worker_id" },
      { "filter_predicates", "=" },
      { "filter_values", "abc" },
    })
    assert_eq("filter_keys=worker_id&filter_predicates=%3D&filter_values=abc", encoded)
  end)

  it("formats entry labels", function()
    local label = util.entry_label({
      cluster = "k8s",
      func_or_class_name = "MyActor.step",
      actor_id = "abc",
      state = "RUNNING",
      host = "10.0.0.1",
      port = 1234,
    })
    assert_eq("[k8s] MyActor.step (actor) RUNNING @ 10.0.0.1:1234", label)
  end)

  it("marks post-mortem entries with the error type", function()
    local label = util.entry_label({
      cluster = "default",
      func_or_class_name = "explode",
      state = "FAILED",
      error_type = "ValueError",
      host = "127.0.0.1",
      port = 4321,
    })
    assert_eq("explode FAILED [ValueError] @ 127.0.0.1:4321", label)
  end)
end)
