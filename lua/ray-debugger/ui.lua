---Picker integration.
---
---Uses `vim.ui.select` by default, which means LazyVim setups with
---telescope-ui-select, fzf-lua, snacks.nvim, etc. get their usual picker
---without any extra configuration.
local M = {}

local config = require("ray-debugger.config")
local util = require("ray-debugger.util")

---Show the paused task picker.
---@param entries RayDebuggerEntry[]
---@param on_choice fun(entry?: RayDebuggerEntry)
function M.pick(entries, on_choice)
  if config.options.picker then
    return config.options.picker(entries, on_choice)
  end

  vim.ui.select(entries, {
    prompt = "Paused Ray tasks",
    kind = "ray-debugger",
    format_item = util.entry_label,
  }, function(choice)
    on_choice(choice)
  end)
end

return M
