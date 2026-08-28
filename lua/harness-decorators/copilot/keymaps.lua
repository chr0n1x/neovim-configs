-- Copilot harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). Copilot supports @file mentions, but isn't the real `claude` binary, so
-- claudecode.nvim's server-backed ClaudeCodeAdd/ClaudeCodeSend do nothing. The
-- context-injection logic (type_into_terminal / build_context_text /
-- send_visual_selection) plus the CopilotAdd / CopilotTreeAdd user-commands live
-- here.

-- ==========================================================================
-- CONTEXT INJECTION
-- ==========================================================================

---Find the floating copilot terminal window (a non-hidden terminal buffer).
---@return number? Window ID or nil if not running
local function find_copilot_terminal_win()
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

---Shorten a path for display. The Copilot CLI reads files itself, so the reference
---just needs to be unambiguous and short. Preference order:
---  1. cwd-relative (e.g. "lua/harness-decorators/copilot/keymaps.lua") when the file
---     is under the current working dir - shortest and matches how you'd type it.
---  2. ~ collapse (e.g. "~/Code/kran/...") when under $HOME but not under cwd.
---  3. the full path otherwise.
---@param file_path string
---@return string
local function shorten_path(file_path)
  -- 1. cwd-relative. Strip the cwd prefix when the file lives under it, yielding a
  --    short relative path like "lua/harness-decorators/copilot/keymaps.lua". Only
  --    accept when there's actually a remainder (a bare filename under cwd is fine too).
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

---Build a Copilot @file mention. Line ranges use the same #L<start>-<end> form
---Claude Code uses (e.g. @<path>#L31-32), so references look consistent across
---harnesses.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function build_context_text(file_path, start_line, end_line)
  file_path = shorten_path(file_path)
  if not (start_line and end_line) then
    return " @" .. file_path
  end
  local range = start_line == end_line and ("#L" .. start_line) or ("#L" .. start_line .. "-" .. end_line)
  return " @" .. file_path .. range
end

---Write text into the copilot terminal's PTY via chansend (same mechanism as
---claudecode.nvim). Multi-line text is wrapped in bracketed-paste markers so
---newlines arrive as one literal block instead of premature submits. We do NOT
---auto-submit - the text lands in copilot's input for you to review and send.
---@param text string
local function type_into_terminal(text)
  local win = find_copilot_terminal_win()
  if not win then
    vim.cmd("ClaudeCodeOpen")
    win = find_copilot_terminal_win()
    if not win then
      vim.notify("copilot: terminal did not open", vim.log.levels.WARN)
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
    vim.notify("copilot: no terminal channel (process may have exited)", vim.log.levels.WARN)
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
    vim.notify("copilot: terminal channel is closed (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- Send the separator separately. Copilot's line editor can discard trailing
  -- whitespace when it arrives in the same PTY write as an @file reference.
  if not normalized:match("[%s ]$") then
    local ok_space, space_written = pcall(vim.fn.chansend, chan, " ")
    if not ok_space or space_written == 0 then
      vim.notify("copilot: failed to add spacing after file reference", vim.log.levels.WARN)
      return nil
    end
  end

  -- chansend writes to the PTY without moving focus; jump to the copilot terminal
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

---Send a visual selection (with its file path + line range) to the copilot terminal.
local function send_visual_selection()
  local file_path = vim.fn.expand("%:p")

  if vim.fn.mode():match("[vV]") then
    -- Exit visual first so the '< / '> marks are set to the true selection
    -- bounds. A captured anchor (where v was pressed) is wrong for text-object
    -- motions like vap, where the selection starts before the entry point; and
    -- the marks are only written when visual mode ends, so we must leave it.
    -- feedkeys with 'x' fully consumes the <Esc> so no stray byte leaks into
    -- the terminal's insert mode after startinsert() below.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    local start_line = vim.fn.line("'<")
    local end_line = vim.fn.line("'>")
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    type_into_terminal(build_context_text(file_path, start_line, end_line))
    return
  end

  -- Normal mode: the whole buffer.
  type_into_terminal(build_context_text(file_path))
end

-- ==========================================================================
-- USER COMMANDS (replace claudecode's server-backed ClaudeCodeAdd/TreeAdd)
-- ==========================================================================

---CopilotAdd: adds a file (or line range) to the copilot terminal as a path reference.
---Usage: CopilotAdd <file-path> [start-line] [end-line]
vim.api.nvim_create_user_command("CopilotAdd", function(opts)
  if not opts.args or opts.args == "" then
    vim.notify("copilot: no file path provided", vim.log.levels.WARN)
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
    vim.notify("copilot: not a readable file: " .. file_path, vim.log.levels.WARN)
    return
  end

  local start_line = args[2] and tonumber(args[2]) or nil
  local end_line = args[3] and tonumber(args[3]) or nil
  if start_line and end_line and start_line > end_line then
    vim.notify("copilot: start line must be <= end line", vim.log.levels.WARN)
    return
  end

  type_into_terminal(build_context_text(file_path, start_line, end_line))
end, { nargs = "+", complete = "file" })

---CopilotTreeAdd: sends the file(s) under the cursor / selected in the tree plugin as
---bare path references. Reuses claudecode.nvim's server-independent tree detection.
vim.api.nvim_create_user_command("CopilotTreeAdd", function()
  local ok, integrations = pcall(require, "claudecode.integrations")
  if not ok then
    vim.notify("copilot: claudecode.integrations not available", vim.log.levels.WARN)
    return
  end
  local files, err = integrations.get_selected_files_from_tree()
  if err or not files or #files == 0 then
    vim.notify("copilot: no file selected in tree" .. (err and (" (" .. err .. ")") or ""), vim.log.levels.WARN)
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

-- ==========================================================================
-- PER-KEY ENTRIES (consumed by ai-harness.lua's consolidated keys table)
-- ==========================================================================

return {
  { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Copilot", mode = { "n", "x" } },
  { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Copilot" },
  {
    "<leader>cu",
    function()
      require("harness-decorators.telescope-history-picker").pick()
    end,
    desc = "view list of changes copilot made.",
    mode = { "n" },
  },
  { "<leader>ca", "<cmd>CopilotAdd %<cr>", desc = "Add current buffer" },
  -- visual: send the selected lines (path + range) to the copilot terminal
  { "<leader>ca", send_visual_selection, mode = "v", desc = "Send selection to Copilot" },
  {
    "<C-t>",
    "<cmd>CopilotTreeAdd<cr>",
    desc = "Add file to Copilot",
    ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
  },
}
