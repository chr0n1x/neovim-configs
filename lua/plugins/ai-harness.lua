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

local function animate_collapse(self)
  if not (self._wide and self._saved_config) then
    return
  end
  self._wide = false
  local sc = self._saved_config
  local anim = require("terminal-animations")
  anim.animate_resize(self, {
    row = sc.row or 0,
    col = sc.col or 0,
    width = sc.width or vim.o.columns,
    height = sc.height or vim.o.lines,
  }, self._saved_config)
end

-- Find the window beside the floating terminal - no cleaner way exists (still).
-- Specifically written to go back to the previous window BECAUSE
-- we're using a floating terminal

local function valid_buf(win_id)
  local config = vim.api.nvim_win_get_config(win_id)
  local buf_info = vim.api.nvim_win_get_buf(win_id)
  local buf_name = vim.api.nvim_buf_get_name(buf_info)
  local terminal_win = vim.api.nvim_get_current_win()

  return not config.z and win_id ~= terminal_win and vim.uv.fs_stat(buf_name) ~= nil
end

local function find_base_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)

  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    if valid_buf(win_id) then
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end
end

local set_prev_win = function()
  find_base_window()
end

---Jump back to the window we came from while the terminal stays open (the "jump
---back" key). Goes to focus.last_win (the actual previous window), falling back to
---the positional set_prev_win if that window is gone. The terminal is config-hidden
---(not closed) first: closing it with self:hide() while a work buffer is showing in
---its window makes Snacks' fixbuf swap the buffer into another window, which
---duplicates buffers. With the float hidden there is nothing to react to; the
---terminal reappears via <leader>c (ClaudeCodeFocus -> cc_show un-hides it).
local function go_back(self)
  focus.suppress_next_leave()
  animate_collapse(self)
  local term = require("claudecode").state and require("claudecode").state.terminal
  if term and term.win and vim.api.nvim_win_is_valid(term.win) then
    pcall(vim.api.nvim_win_set_config, term.win, { hide = true })
  end
  if not focus.jump_to_saved() then
    set_prev_win()
  end
  vim.cmd.redraw()
  vim.cmd("noh")
end

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

      terminal = {
        provider = "auto",
        auto_close = true,

        snacks_win_opts = {
          position = "float",
          border = "rounded",
          title = title.title(harness),
          -- Snacks' style default maps FloatTitle:SnacksTitle, which overrides
          -- the per-segment groups in `title`. Set winhighlight after all merging
          -- is done so our override sticks.
          on_win = function(self)
            vim.api.nvim_set_option_value("winhighlight", "FloatFooter:SnacksFooter", { win = self.win })
          end,
          footer_keys = true,
          -- Disabled: fixbuf registers a BufWinEnter autocmd that swaps the float's
          -- buffer into a "main" window whenever a non-terminal buffer lands in the
          -- float. During the float's destroy/recreate (cc_show -> Snacks open_win)
          -- or any concurrent focus change, that swap duplicates buffers. Every keymap
          -- here manages focus explicitly and cc_show always sets the terminal buffer
          -- back, so nothing relies on fixbuf - dropping it removes the duplication.
          fix_buf = false,
          resize = true,
          stack = true,
          start_insert = true,

          keys = {
            {
              "<Esc>",
              function(self)
                -- Suppress capture for hide's WinLeave (we already moved to a base
                -- window via set_prev_win); no restore needed - the buffer was never
                -- changed and set_prev_win put us back where we came from.
                focus.suppress_next_leave()
                set_prev_win()
                self:hide()
                vim.cmd.redraw()
                vim.cmd("noh")
              end,
              mode = "t",
              desc = "⊘",
            },

            {
              "<C-n>",
              function()
                vim.cmd.stopinsert()
                vim.cmd("noautocmd stopinsert")
              end,
              mode = "t",
              desc = "✥",
            },
            {
              "<C-h>",
              function(self)
                go_back(self)
              end,
              mode = "t",
              desc = "↩",
            },
            {
              "<C-f>",
              function(self)
                local win = self.win
                if not win or not vim.api.nvim_win_is_valid(win) then
                  return
                end

                -- Save original config only once so we don't drift on each toggle
                if not self._saved_config then
                  self._saved_config = vim.api.nvim_win_get_config(win)
                end

                local lines = vim.o.lines
                local cols = vim.o.columns
                local wide_row_pad = 0.05
                local wide_col_pad = 0.1

                if not self._wide then
                  self._wide = true
                  local anim = require("terminal-animations")
                  anim.animate_resize(self, {
                    row = wide_row_pad * lines,
                    col = wide_col_pad * cols,
                    width = (1 - 2 * wide_col_pad) * cols,
                    height = (1 - 2 * wide_row_pad) * lines,
                  })
                else
                  animate_collapse(self)
                end
              end,
              mode = "t",
              desc = "⛶",
            },
          },

          -- TODO: make these...more relative
          row = 0.01,
          col = 0.58,
          width = 0.35,
          height = 0.9,
        },
      },
    }, opts_overrides),
  },
}
