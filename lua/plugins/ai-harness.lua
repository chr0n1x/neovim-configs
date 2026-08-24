-- claudecode.nvim terminal integration shared by the claude and maki harnesses:
-- floating CLI terminal with focus restoration on alt-tab. Per-harness keymap
-- implementations live in lua/harness-decorators/<harness>/keymaps.lua; the
-- binding strings are consolidated here into one keys table.
local harness = os.getenv("NVIM_LLM_HARNESS") or "claude"
if harness ~= "claude" and harness ~= "maki" then
  return {}
end

-- Per-harness terminal command (CLI + model flags); each harness sets its own env.
local command = require("harness-decorators." .. harness .. ".env")

-- save current window before alt-tab so we can restore focus on return
local _last_win = vim.api.nvim_get_current_win()
vim.api.nvim_create_autocmd("FocusLost", {
  pattern = "*",
  callback = function()
    _last_win = vim.api.nvim_get_current_win()
  end,
})

vim.api.nvim_create_autocmd("FocusGained", {
  pattern = "*",
  callback = function()
    -- after alt-tab, snacks/tmux loses cursor focus on the floating
    -- terminal; restore to whatever window had it before we left
    vim.cmd.redraw()
    if vim.api.nvim_win_is_valid(_last_win) then
      vim.api.nvim_set_current_win(_last_win)
      local buf = vim.api.nvim_win_get_buf(_last_win)
      if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
        vim.cmd.startinsert()
      end
    end
  end,
})

vim.api.nvim_create_autocmd("ExitPre", {
  pattern = "*",
  callback = function()
    if harness == "claude" then
      vim.cmd("silent! ClaudeCodeClose<CR>")
      vim.cmd("silent! ClaudeCodeStop<CR>")
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end,
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

local function find_base_window(reverse)
  local wins = vim.api.nvim_tabpage_list_wins(0)

  if reverse then
    for _, win_id in ipairs(wins) do
      if valid_buf(win_id) then
        vim.api.nvim_set_current_win(win_id)
        return
      end
    end
    return
  end

  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    if valid_buf(win_id) then
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end
end

local set_prev_win = function()
  find_base_window(false)
end

local set_next_win = function()
  find_base_window(true)
end

-- Per-harness opts differences (everything else in `opts` is shared).
local opts_overrides = {
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = true,
    keep_terminal_focus = false,
    hide_terminal_in_new_tab = true,
    on_new_file_reject = "close_window",
  },
}
if harness == "maki" then
  opts_overrides.auto_start = false
else
  opts_overrides.auto_start = true
  opts_overrides.focus_after_send = true -- after <leader>ca go to terminal
end

-- Consolidated <leader>c* keymaps. Each harness's keymaps.lua returns its own list of
-- lazy.nvim key specs (lhs, action, desc, mode/ft); ai-harness.lua just wires it in so
-- there is exactly one keys table for the plugin spec.
local keys = require("harness-decorators." .. harness .. ".keymaps")

return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    config = true,
    opts = vim.tbl_extend("force", {
      terminal_cmd = command,
      log_level = "info",

      terminal = {
        provider = "auto",
        auto_close = true,

        snacks_win_opts = {
          position = "float",
          border = "rounded",
          footer_keys = true,
          fix_buf = true,
          resize = true,
          stack = true,
          start_insert = true,

          keys = {
            {
              "<Esc>",
              function(self)
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
                animate_collapse(self)
                set_prev_win()
                vim.cmd.redraw()
                vim.cmd("noh")
              end,
              mode = "t",
              desc = "←",
            },
            {
              "<C-l>",
              function(self)
                animate_collapse(self)
                set_next_win()
                vim.cmd.redraw()
                vim.cmd("noh")
              end,
              mode = "t",
              desc = "→",
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
    keys = keys,
  },
}
