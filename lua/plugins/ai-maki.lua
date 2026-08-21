-- Maki terminal integration.
-- Spawns a floating terminal running the `maki` CLI and handles
-- focus restoration when alt-tabbing in/out of Neovim.
-- Only active when NVIM_LLM_HARNESS == "maki" (default is "claude").
if os.getenv("NVIM_LLM_HARNESS") ~= "maki" then
  return {}
end

local command = "maki"
local maki_cmd_env = os.getenv("MAKI_COMMAND")

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
    -- maki terminal; restore to whatever window had it before we left
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
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end,
})

-- MAKI_MODEL env var (provider/model-id spec) for the default model
local maki_model = os.getenv("MAKI_MODEL") or ""
if maki_cmd_env and maki_cmd_env ~= "" then
  command = maki_cmd_env
elseif maki_model ~= "" then
  command = "maki -m " .. maki_model
end

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

-- Find the window beside the floating terminal — no cleaner way exists (still).
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

-- --- Context injection -------------------------------------------------------
-- maki has no @file mention expansion and reads piped stdin as the initial
-- prompt, so "adding" a file means typing its (path-labeled) content into the
-- floating terminal. We locate the snacks.maker terminal window ourselves and
-- feed text into it; if it isn't running we open it first via ClaudeCodeOpen.

local function find_maki_terminal_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if not (ok and cfg and cfg.hide) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
        return win
      end
    end
  end
end

-- Build a path-labeled snippet. Whole files get just the header (maki can read
-- the file itself); ranges get the actual lines inlined so they're in context.
-- maki reads files itself, so context is always just a path reference:
-- <path>, <path>:<line>, or <path>:<line1>-<line2>.
local function build_context_text(file_path, start_line, end_line)
  if not (start_line and end_line) then
    return file_path
  end
  return start_line == end_line and (file_path .. ":" .. start_line)
    or (file_path .. ":" .. start_line .. "-" .. end_line)
end

-- Write text into the maki terminal's PTY via chansend (same mechanism as
-- claudecode.nvim). Multi-line text is wrapped in bracketed-paste markers so
-- newlines arrive as one literal block instead of premature submits. We do NOT
-- auto-submit — the text lands in maki's input for you to review and send.
local function type_into_terminal(text)
  local win = find_maki_terminal_win()
  if not win then
    vim.cmd("ClaudeCodeOpen")
    win = find_maki_terminal_win()
    if not win then
      vim.notify("maki: terminal did not open", vim.log.levels.WARN)
      return nil
    end
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  -- termopen() sets b:terminal_job_id; bo.channel is the robust fallback.
  local chan = vim.b[bufnr] and vim.b[bufnr].terminal_job_id
  if not chan or chan == 0 then
    chan = vim.bo[bufnr].channel
  end
  if not chan or chan == 0 then
    vim.notify("maki: no terminal channel (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- Normalize so the only line breaks are \n; wrap multi-line in bracketed paste.
  local normalized = (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
  local payload = normalized
  if string.find(normalized, "\n", 1, true) then
    payload = "\27[200~" .. normalized .. "\27[201~"
  end

  local ok_send, written = pcall(vim.fn.chansend, chan, payload)
  if not ok_send or written == 0 then
    vim.notify("maki: terminal channel is closed (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- chansend writes to the PTY without moving focus; jump to the maki terminal
  -- and enter insert mode so you can review/edit/submit the added context.
  -- Drop any active visual selection first: switching windows while in visual
  -- mode exits it and parks the cursor on '>, which then poisoned later sends.
  if vim.fn.mode() == "V" or vim.fn.mode() == "v" then
    vim.cmd("normal! gv")
    vim.cmd("normal! lv")
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.startinsert()
  return win
end

-- Capture the start line when visual mode begins. We hook the v/V/Ctrl-v keys
-- directly (keymaps are reliable here; a ModeChanged autocmd never fired, and
-- the '< mark reads stale), stashing where the selection began.
local _vis_start_line = nil
local function capture_vis_start()
  _vis_start_line = vim.fn.line(".")
end

-- Capture the start line when visual mode begins. We wrap the v/V/Ctrl-v keys:
-- record the cursor line, then re-issue the original key so normal visual
-- behavior is unchanged. (A ModeChanged autocmd never fired in this setup and
-- the '< mark reads stale, so we track the anchor ourselves.)
for _, key in ipairs({ "v", "V", "<C-v>" }) do
  vim.keymap.set("n", key, function()
    capture_vis_start()
    -- Re-issue the original visual-mode key (Ctrl-v is byte 0x16).
    local raw = key == "<C-v>" and "\22" or key
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(raw, true, false, true), "n", false)
  end, { desc = "Visual (capture start for Maki)" })
end

-- Send a visual selection (with its file path + line range) to the maki
-- terminal. chansend writes straight to the PTY, so no mode juggling needed.
local function send_visual_selection()
  local file_path = vim.fn.expand("%:p")

  if vim.fn.mode():match("[vV]") then
    -- End is the cursor's line (always live); start is where visual began.
    local end_line = vim.fn.line(".")
    local start_line = _vis_start_line or end_line
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    type_into_terminal(build_context_text(file_path, start_line, end_line))
    return
  end

  -- Normal mode: the whole buffer.
  type_into_terminal(build_context_text(file_path))
end

-- Custom MakiAdd: replaces ClaudeCodeAdd (which needs claudecode's server).
-- Usage: MakiAdd <file-path> [start-line] [end-line]
vim.api.nvim_create_user_command("MakiAdd", function(opts)
  if not opts.args or opts.args == "" then
    vim.notify("maki: no file path provided", vim.log.levels.WARN)
    return
  end
  local args = vim.split(opts.args, "%s+")
  local file_path = args[1]

  -- Expand vim tokens (% # <cfile> ...) and a leading ~; expand() leaves
  -- literal $ in paths intact, so TanStack-style $param files survive.
  if file_path:match("^[%%#<~]") then
    file_path = vim.fn.expand(file_path)
  end

  if vim.fn.filereadable(file_path) == 0 then
    vim.notify("maki: not a readable file: " .. file_path, vim.log.levels.WARN)
    return
  end

  local start_line = args[2] and tonumber(args[2]) or nil
  local end_line = args[3] and tonumber(args[3]) or nil
  if start_line and end_line and start_line > end_line then
    vim.notify("maki: start line must be <= end line", vim.log.levels.WARN)
    return
  end

  type_into_terminal(build_context_text(file_path, start_line, end_line))
end, { nargs = "+", complete = "file" })

-- MakiTreeAdd: replaces ClaudeCodeTreeAdd (which needs claudecode's server).
-- Sends the file(s) under the cursor / selected in the tree plugin as bare
-- path references. Reuses claudecode.nvim's server-independent tree detection.
vim.api.nvim_create_user_command("MakiTreeAdd", function()
  local ok, integrations = pcall(require, "claudecode.integrations")
  if not ok then
    vim.notify("maki: claudecode.integrations not available", vim.log.levels.WARN)
    return
  end
  local files, err = integrations.get_selected_files_from_tree()
  if err or not files or #files == 0 then
    vim.notify("maki: no file selected in tree" .. (err and (" (" .. err .. ")") or ""), vim.log.levels.WARN)
    return
  end
  local first = true
  for _, path in ipairs(files) do
    if not first then
      type_into_terminal("\n")
    end
    first = false
    type_into_terminal(build_context_text(path))
  end
end, {})

return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    config = true,
    opts = {
      terminal_cmd = command,

      auto_start = false,
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
    },
    keys = {
      { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Maki", mode = { "n", "x" } },
      { "<leader>cr", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Maki" },
      { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Maki" },
      { "<leader>cm", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Maki model" },
      { "<leader>ca", "<cmd>MakiAdd %<cr>", desc = "Add current buffer" },
      -- visual: send the selected lines (path + range) to the maki terminal
      {
        "<leader>ca",
        function()
          send_visual_selection()
        end,
        mode = "v",
        desc = "Send selection to Maki",
      },
      {
        "<C-t>",
        "<cmd>MakiTreeAdd<cr>",
        desc = "Add file to Maki",
        ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
      },
      -- Diff management
      { "<leader>cda", "<cmd>ClaudeCodeDiffAccept<cr>; redraw<cr>", desc = "Accept diff & redraw" },
      { "<leader>cdd", "<cmd>ClaudeCodeDiffDeny<cr>; redraw<cr>", desc = "Deny diff & redraw" },
    },
  },
}
