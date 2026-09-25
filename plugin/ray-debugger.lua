-- ray-debugger.nvim user commands.
--
-- The commands only call into `lua/ray-debugger/` lazily, so having this file
-- on the runtimepath costs nothing at startup.
if vim.g.loaded_ray_debugger == 1 then
  return
end
vim.g.loaded_ray_debugger = 1

local function ray()
  return require("ray-debugger")
end

vim.api.nvim_create_user_command("RayDebug", function()
  ray().pick()
end, {
  desc = "Ray debugger: list paused tasks and attach",
})

vim.api.nvim_create_user_command("RayDebugAttach", function(opts)
  ray().attach_address(opts.args)
end, {
  nargs = "?",
  complete = function()
    local entries = require("ray-debugger").cache.entries
    local completions = {}
    for _, entry in ipairs(entries) do
      completions[#completions + 1] = entry.host .. ":" .. tostring(entry.port)
    end
    return completions
  end,
  desc = "Ray debugger: attach to <host:port | worker-id | task-id>",
})

vim.api.nvim_create_user_command("RayDebugPostMortem", function()
  ray().post_mortem()
end, {
  desc = "Ray debugger: show the post-mortem traceback and locals of the current session",
})

vim.api.nvim_create_user_command("RayDebugWatch", function(opts)
  local arg = opts.args
  local enable
  if arg == "on" then
    enable = true
  elseif arg == "off" then
    enable = false
  end
  local watching = ray().watch(enable)
  require("ray-debugger.util").notify(
    watching and "watching for paused tasks" or "stopped watching for paused tasks",
    vim.log.levels.INFO
  )
end, {
  nargs = "?",
  complete = function()
    return { "on", "off" }
  end,
  desc = "Ray debugger: notify when tasks pause (toggle, or on/off)",
})

vim.api.nvim_create_user_command("RayDebugRefresh", function()
  local ray_debugger = ray()
  ray_debugger.refresh(function(err, entries)
    if err then
      require("ray-debugger.util").notify(err, vim.log.levels.ERROR)
    else
      require("ray-debugger.util").notify(
        string.format("%d paused task(s)", #entries),
        vim.log.levels.INFO
      )
    end
  end)
end, {
  desc = "Ray debugger: refresh the paused task cache",
})
