-- Claude harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). The binding strings and descriptions are harness-specific; ai-harness.lua
-- just concatenates these into its single keys table. The claude harness otherwise uses
-- claudecode.nvim's stock commands as-is, EXCEPT <C-t> tree-add: the stock
-- ClaudeCodeTreeAdd routes through _format_path_for_at_mention, which collapses a
-- directory equal to nvim's cwd to "./", and the CLI then relativizes that against its
-- own (stale) spawn cwd to an empty string - producing a bare "@" in the terminal. So
-- <C-t> uses a local ClaudeTreeAdd that types an unambiguous @<path> mention directly
-- into the terminal (same approach as the maki/copilot harnesses).

-- ==========================================================================
-- CONTEXT INJECTION
-- ==========================================================================

---Find the floating claude terminal window (a non-hidden terminal buffer).
---@return number? Window ID or nil if not running
local function find_claude_terminal_win()
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

---Shorten a path for an @-mention. The claude CLI reads files itself, so the reference
---just needs to be unambiguous and short. Preference order:
---  1. cwd-relative (e.g. "lua/harness-decorators/claude/keymaps.lua") when the file is
---     under the current working dir - shortest and matches how you'd type it.
---  2. ~ collapse (e.g. "~/Code/kran/...") when under $HOME but not under cwd.
---  3. the full path otherwise.
---A directory that IS the cwd has no non-empty remainder in either step, so it falls
---through to the full absolute path - never the empty/"./" form that yields a bare "@".
---@param file_path string
---@return string
local function shorten_path(file_path)
  -- 1. cwd-relative. Strip the cwd prefix when the file lives under it, yielding a
  --    short relative path like "lua/harness-decorators/claude/keymaps.lua". Only accept
  --    when there's actually a remainder (a bare filename under cwd is fine too).
  local cwd = vim.uv.cwd()
  if cwd and cwd ~= "" then
    local bare_cwd = cwd:gsub("/+$", "")
    if bare_cwd ~= "" then
      local prefix = bare_cwd .. "/"
      if file_path:sub(1, #prefix) == prefix then
        local rel = file_path:sub(#prefix + 1)
        if rel ~= "" then
          return rel
        end
      end
    end
  end

  -- 2. ~ collapse for anything under $HOME.
  local home = vim.env.HOME
  if home and home ~= "" then
    local bare_home = home:gsub("/+$", "")
    if bare_home ~= "" then
      if file_path == bare_home then
        return "~"
      end
      -- Only shorten when the path is home + "/" + more, so /home/kran2/foo is NOT
      -- shortened when HOME=/home/kran (the char right after home must be a slash).
      local prefix = bare_home .. "/"
      if file_path:sub(1, #prefix) == prefix then
        return "~/" .. file_path:sub(#prefix + 1)
      end
    end
  end

  -- 3. Full path.
  return file_path
end

---Build a claude @-mention for a tree node. Directories keep a trailing slash so the CLI
---treats the reference as a folder, not a file.
---@param file_path string
---@return string
local function build_context_text(file_path)
  local is_dir = vim.fn.isdirectory(file_path) == 1
  local short = shorten_path(file_path)
  if is_dir and not short:match("/$") then
    short = short .. "/"
  end
  return "@" .. short
end

---Write text into the claude terminal's PTY via chansend (same mechanism as
---claudecode.nvim). Multi-line text is wrapped in bracketed-paste markers so
---newlines arrive as one literal block instead of premature submits. We do NOT
---auto-submit - the text lands in the input for you to review and send.
---@param text string
local function type_into_terminal(text)
  local win = find_claude_terminal_win()
  if not win then
    vim.cmd("ClaudeCodeOpen")
    win = find_claude_terminal_win()
    if not win then
      vim.notify("claude: terminal did not open", vim.log.levels.WARN)
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
    vim.notify("claude: no terminal channel (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- Normalize so the only line breaks are \n; wrap multi-line in bracketed paste.
  local normalized = (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
  local payload = normalized
  if string.find(normalized, "\n", 1, true) then
    payload = "\27[200~" .. normalized .. "\27[201~"
  end

  -- Append a space so the next thing typed doesn't glue onto the inserted text.
  if not normalized:match("[%s ]$") then
    payload = payload .. " "
  end

  local ok_send, written = pcall(vim.fn.chansend, chan, payload)
  if not ok_send or written == 0 then
    vim.notify("claude: terminal channel is closed (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- chansend writes to the PTY without moving focus; jump to the claude terminal and
  -- enter insert mode so you can review/edit/submit the added context. Drop any active
  -- visual selection first: switching windows while in visual mode exits it and parks the
  -- cursor on '>, which then poisoned later sends.
  if vim.fn.mode() == "V" or vim.fn.mode() == "v" then
    vim.cmd("normal! gv")
    vim.cmd("normal! lv")
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.startinsert()
  return win
end

-- ==========================================================================
-- USER COMMAND (replaces claudecode's server-backed ClaudeCodeTreeAdd for <C-t>)
-- ==========================================================================

---ClaudeTreeAdd: sends the file(s)/dir(s) under the cursor / selected in the tree plugin
---as @<path> mentions typed into the terminal. Reuses claudecode.nvim's server-independent
---tree detection, but formats paths locally so a cwd-equal directory never collapses to a
---bare "@".
vim.api.nvim_create_user_command("ClaudeTreeAdd", function()
  local ok, integrations = pcall(require, "claudecode.integrations")
  if not ok then
    vim.notify("claude: claudecode.integrations not available", vim.log.levels.WARN)
    return
  end
  local files, err = integrations.get_selected_files_from_tree()
  if err or not files or #files == 0 then
    vim.notify("claude: no file selected in tree" .. (err and (" (" .. err .. ")") or ""), vim.log.levels.WARN)
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
  { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
  { "<leader>cr", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
  { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
  { "<leader>cm", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
  {
    "<leader>cu",
    function()
      require("harness-decorators.telescope-history-picker").pick()
    end,
    desc = " view list of changes claude made.",
    mode = { "n" },
  },
  { "<leader>ca", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
  -- esc required to exit visual mode after going into terminal
  { "<leader>ca", "<cmd>ClaudeCodeSend<cr>; <esc>", mode = "v", desc = "Send to Claude" },
  {
    "<C-t>",
    "<cmd>ClaudeTreeAdd<cr>",
    desc = "Add file",
    ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
  },
  -- Diff management - I barely use these but wanted to give some defaults
  -- that fall under <leader>c
  { "<leader>cda", "<cmd>ClaudeCodeDiffAccept<cr>; redraw<cr>", desc = "Accept diff & redraw" },
  { "<leader>cdd", "<cmd>ClaudeCodeDiffDeny<cr>; redraw<cr>", desc = "Deny diff & redraw" },
}
