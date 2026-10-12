-- AI harness wiring (claude / copilot / maki / crush / pi). This used to be the lazy.nvim spec
-- for coder/claudecode.nvim, but the plugin is no longer a dependency: the floating terminal is
-- owned by harness-decorators/term.lua (one Snacks float per harness), tree selection is our own
-- neo-tree selector (harness-decorators/tree-select), and there is no websocket server or diff
-- view to run. All that remains is registering our keymaps and the two session-lifetime autocmds,
-- which now live in harness-decorators.init.setup. This file exists only so lazy.nvim's
-- `{ import = "plugins" }` still finds a (now empty) spec at this path; the real work is the
-- require below, which runs at startup because this file has no lazy-load trigger.
local utils = require("harness-decorators.utils")
local harness = os.getenv("NVIM_LLM_HARNESS") or "claude"

if vim.tbl_contains(utils.list_harnesses(), harness) then
  require("harness-decorators").setup(harness)
  -- Open the harness float on startup so the terminal is already up (the <leader>c behavior,
  -- without the keystroke). Spawning a harness process in headless (the test suite) never
  -- settles, so the auto-open is skipped there. Schedules so it runs after the UI is ready.
  if not vim.fn.has("headless") then
    vim.schedule(function()
      require("harness-decorators").open_on_startup()
    end)
  end
end

return {}
