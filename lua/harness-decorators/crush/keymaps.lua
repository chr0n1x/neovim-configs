-- Crush harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). crush is a self-contained TUI: it reads files itself (no @file mention
-- server) and stores sessions in SQLite rather than JSONL, so the live edit-following
-- watcher is disabled for it (see crush/init.lua). That leaves nothing for the
-- copilot/maki-style edit-history picker to hang off, but <C-t> tree-add still makes
-- sense: type the selected path into the crush terminal as a bare reference you can
-- weave into your prompt. The context-injection logic (type_into_terminal /
-- shorten_path) plus the CrushTreeAdd user-command live here.

-- ==========================================================================
-- CONTEXT INJECTION
-- ==========================================================================

---Find the floating crush terminal window (a non-hidden terminal buffer).
---@return number? Window ID or nil if not running
local function find_crush_terminal_win()
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

---Shorten a path for display. crush reads files itself, so the reference just needs to
---be unambiguous and short. Preference order:
---  1. cwd-relative (e.g. "lua/harness-decorators/crush/keymaps.lua") when the file is
---     under the current working dir - shortest and matches how you'd type it.
---  2. ~ collapse (e.g. "~/Code/kran/...") when under $HOME but not under cwd.
---  3. the full path otherwise.
---@param file_path string
---@return string
local function shorten_path(file_path)
  -- 1. cwd-relative. Strip the cwd prefix when the file lives under it, yielding a
  --    short relative path like "lua/harness-decorators/crush/keymaps.lua". Only accept
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

---Build a crush path reference. crush has no @file mention syntax, so this is just the
---shortened path (no leading @). A directory keeps a trailing slash so it reads as a
---folder, not a file.
---@param file_path string
---@return string
local function build_context_text(file_path)
  local short = shorten_path(file_path)
  if vim.fn.isdirectory(file_path) == 1 and not short:match("/$") then
    short = short .. "/"
  end
  return short
end

---Write text into the crush terminal's PTY via chansend (same mechanism as
---claudecode.nvim). Multi-line text is wrapped in bracketed-paste markers so
---newlines arrive as one literal block instead of premature submits. We do NOT
---auto-submit - the text lands in crush's input for you to review and send.
---@param text string
local function type_into_terminal(text)
  local win = find_crush_terminal_win()
  if not win then
    vim.cmd("ClaudeCodeOpen")
    win = find_crush_terminal_win()
    if not win then
      vim.notify("crush: terminal did not open", vim.log.levels.WARN)
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
    vim.notify("crush: no terminal channel (process may have exited)", vim.log.levels.WARN)
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
    vim.notify("crush: terminal channel is closed (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- chansend writes to the PTY without moving focus; jump to the crush terminal and
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
-- USER COMMAND (tree add for <C-t>)
-- ==========================================================================

---CrushTreeAdd: sends the file(s)/dir(s) under the cursor / selected in the tree plugin
---as bare path references typed into the crush terminal. Reuses claudecode.nvim's
---server-independent tree detection, but formats paths locally (crush has no @file
---mention server to route through).
vim.api.nvim_create_user_command("CrushTreeAdd", function()
  local files, err = require("harness-decorators.utils").get_tree_selection()
  if not files or #files == 0 then
    vim.notify("crush: no file selected in tree" .. (err and (" (" .. err .. ")") or ""), vim.log.levels.WARN)
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
  { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Crush", mode = { "n", "x" } },
  { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Crush" },
  {
    "<C-t>",
    "<cmd>CrushTreeAdd<cr>",
    desc = "Add file to Crush",
    ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
  },
}
