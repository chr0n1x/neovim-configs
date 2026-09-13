-- claudecode.nvim terminal integration shared by the claude and maki harnesses:
-- floating CLI terminal with focus restoration on alt-tab. Per-harness keymap
-- implementations live in lua/harness-decorators/<harness>/keymaps.lua; the
-- binding strings are consolidated here into one keys table.
--
-- The consolidated <leader>c* table (harness entries + <leader>cl switcher) lives in
-- harness-decorators/keymaps.lua. <leader>c opens/focuses the floating terminal and,
-- on first open, starts the JSONL watcher; <leader>cl opens a Telescope picker
-- (harness-decorators/switch.lua) over the available lua/harness-decorators/<dir>
-- harnesses and swaps the backing CLI at runtime: it kills the floating terminal,
-- repoints claudecode.nvim's terminal_cmd, and rebinds these <leader>c*/ft keymaps
-- to the chosen harness. The websocket server auto-starts (claudecode.nvim default)
-- so context keys work from the first <leader>ca press; the floating terminal itself
-- only opens on demand via <leader>c.
local switch = require("harness-decorators.switch")
local title = require("harness-decorators.title")

-- Re-define title groups after colorscheme switches (nord does `hi clear`).
vim.api.nvim_create_autocmd("ColorScheme", {
  pattern = "*",
  callback = title.define_all,
})

local harness = os.getenv("NVIM_LLM_HARNESS") or "claude"
local keymaps = require("harness-decorators.keymaps")
if not vim.tbl_contains(keymaps.list_harnesses(), harness) then
  return {}
end

-- Per-harness terminal command (CLI + model flags); each harness sets its own env.
-- Requiring the env module here (not referencing an undefined global) is what makes
-- terminal_cmd correct at startup - without it, claudecode falls back to "claude" and a
-- fresh NVIM_LLM_HARNESS=maki silently runs claude (the A1 desync).
local command = require("harness-decorators." .. harness .. ".env")

-- Remember the last normal-mode buffer so focus-gaining actions can restore it.
-- WinLeave fires the instant a window loses focus, so this always holds the
-- window we came from before the terminal took over. The restore lives in
-- focus.lua and is invoked from every path that moves focus into the terminal.
local focus = require("harness-decorators.focus")
vim.api.nvim_create_autocmd("WinLeave", {
  pattern = "*",
  callback = focus.capture,
})

-- NOTE (Task 7): the floating terminal is now owned by harness-decorators/term.lua - one Snacks
-- float per harness, no claudecode handle. The float's keys, resize animation, and go-back that used
-- to live here moved into term.win_opts. This file keeps only what claudecode still provides: its
-- websocket server (@ mention queue, model selection) and diff accept/deny.

-- Per-harness opts differences (everything else in `opts` is shared). auto_start
-- controls the websocket server only - it has no effect on the floating terminal,
-- which opens on the first <leader>c press (that press also starts the JSONL watcher,
-- see harness-decorators/keymaps.lua). The server must be up for <leader>ca /
-- <C-t> to deliver @ mentions: with auto_start = false nothing ever calls M.start(),
-- so send_at_mention() bails on `not M.state.server` and the context keys are dead.
local opts_overrides = {
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = true,
    keep_terminal_focus = false,
    hide_terminal_in_new_tab = true,
    on_new_file_reject = "close_window",
  },
}
if harness ~= "maki" then
  opts_overrides.focus_after_send = true -- after <leader>ca go to terminal
end

return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    config = function(_, opts)
      require("claudecode").setup(opts)
      -- Register the consolidated <leader>c* keymaps (harness entries + <leader>cl
      -- switcher) and record initial harness state for switch.lua. The terminal is
      -- not started here; the first <leader>c press opens it (and starts the watcher).
      keymaps.apply(keymaps.build(harness))
      switch.init(harness)
    end,
    opts = vim.tbl_extend("force", {
      terminal_cmd = command,
      log_level = "info",

      -- The floating terminal is owned by harness-decorators/term.lua (one Snacks float per
      -- harness), NOT claudecode's snacks provider - so no snacks_win_opts here. claudecode still
      -- runs its websocket server (for @ mention queue + model selection) and diff accept/deny, but
      -- we never show ITS window. auto_close is off: term.lua owns open/hide, and Snacks'
      -- auto-close would kill a backgrounded harness's PTY on an unrelated event.
      terminal = {
        provider = "auto",
        auto_close = false,
      },
    }, opts_overrides),
  },
}
