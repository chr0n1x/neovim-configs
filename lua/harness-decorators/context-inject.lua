-- Shared context-injection helpers for the per-harness keymaps files. The four harnesses
-- (claude/copilot/crush/maki) each need to type a path reference into their floating
-- terminal, and the machinery for finding that window, shortening the path, and writing
-- to its PTY was copy-pasted verbatim across all four keymaps.lua files. This module is
-- the single home for that shared logic; each harness keeps only what genuinely differs:
-- its build_context_text format (claude @path + dir slash, copilot/maki optional #L range,
-- crush bare path) and the command names / notify prefix it registers under.
local M = {}

---Find the floating harness terminal window (a non-hidden buffer with buftype=="terminal").
---Identical across all four harnesses; there is exactly one visible terminal float at a
---time, so no per-harness filtering is needed.
---@return number? Window ID or nil if not running
function M.find_terminal_win()
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

---Shorten a path for display in the harness terminal. Delegates to the shared definition in
---utils.shorten_path (cwd-relative, then ~ collapse, then full). The per-harness @/range/decor
---is applied by each keymaps file on top of this result.
---@param file_path string
---@return string
function M.shorten_path(file_path)
  return require("harness-decorators.utils").shorten_path(file_path)
end

---Write text into the harness terminal's PTY via chansend (same mechanism as
---claudecode.nvim). Multi-line text is wrapped in bracketed-paste markers so newlines
---arrive as one literal block instead of premature submits. We do NOT auto-submit - the
---text lands in the input for you to review and send.
---@param text string
---@param opts? table { separate_space = boolean } When true, the trailing space (added so
---  the next keystroke doesn't glue onto the inserted text) is sent as its OWN chansend
---  with a separate error check. Copilot's line editor can discard trailing whitespace when
---  it arrives in the same PTY write as an @file reference, so copilot passes this; the
---  other harnesses append the space inline and default to false.
---@param harness string Notify prefix (e.g. "claude", "copilot").
---@return number? Window ID on success, nil on failure (a warning is emitted).
function M.type_into_terminal(text, opts, harness)
  local separate_space = opts and opts.separate_space or false

  local win = M.find_terminal_win()
  if not win then
    -- No visible terminal: open OUR per-harness float (term.open), NOT claudecode's stock
    -- ClaudeCodeOpen - that would spawn a second, claudecode-owned window in a separate pane
    -- instead of typing into the one we own. term.open re-shows the same live process if the
    -- harness was already running (just hidden), or spawns fresh otherwise.
    local ok_term, term = pcall(require, "harness-decorators.term")
    if ok_term then
      term.open(harness)
    end
    win = M.find_terminal_win()
    if not win then
      vim.notify(harness .. ": terminal did not open", vim.log.levels.WARN)
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
    vim.notify(harness .. ": no terminal channel (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- Normalize so the only line breaks are \n; wrap multi-line in bracketed paste.
  local normalized = (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
  local payload = normalized
  if string.find(normalized, "\n", 1, true) then
    payload = "\27[200~" .. normalized .. "\27[201~"
  end

  -- Append a space so the next thing typed doesn't glue onto the inserted text, unless
  -- the text already ends in whitespace (e.g. TreeAdd's "\n" separator). With
  -- separate_space the space is sent on its own write instead of being glued on here.
  if not normalized:match("[%s ]$") and not separate_space then
    payload = payload .. " "
  end

  local ok_send, written = pcall(vim.fn.chansend, chan, payload)
  if not ok_send or written == 0 then
    vim.notify(harness .. ": terminal channel is closed (process may have exited)", vim.log.levels.WARN)
    return nil
  end

  -- Send the separator separately when requested. Copilot's line editor can discard
  -- trailing whitespace when it arrives in the same PTY write as an @file reference, so it
  -- must be its own write with its own error check.
  if separate_space and not normalized:match("[%s ]$") then
    local ok_space, space_written = pcall(vim.fn.chansend, chan, " ")
    if not ok_space or space_written == 0 then
      vim.notify(harness .. ": failed to add spacing after file reference", vim.log.levels.WARN)
      return nil
    end
  end

  -- chansend writes to the PTY without moving focus; jump to the harness terminal so you can
  -- review/edit/submit the added context. term.lua's shared WinEnter handler enters terminal mode.
  -- Drop any active visual
  -- selection first: switching windows while in visual mode exits it and parks the cursor on
  -- '>, which then poisoned later sends.
  if vim.fn.mode() == "V" or vim.fn.mode() == "v" then
    vim.cmd("normal! gv")
    vim.cmd("normal! lv")
  end
  vim.api.nvim_set_current_win(win)
  return win
end

---Build the shared TreeAdd user-command body: get the tree selection, warn if empty, then
---type each path (separated by newlines) into the terminal via build_context_text. The only
---per-harness inputs are the command name, the notify prefix, and the harness's own
---build_context_text (which formats the reference differently).
---@param cmd_name string e.g. "ClaudeTreeAdd"
---@param harness string Notify prefix.
---@param type_into_terminal fun(text: string): number? The harness-bound send function.
---@param build_context_text fun(file_path: string): string The harness's reference formatter.
function M.make_tree_add_command(cmd_name, harness, type_into_terminal, build_context_text)
  vim.api.nvim_create_user_command(cmd_name, function()
    local files, err = require("harness-decorators.utils").get_tree_selection()
    if not files or #files == 0 then
      vim.notify(harness .. ": no file selected in tree" .. (err and (" (" .. err .. ")") or ""), vim.log.levels.WARN)
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
end

---Build the shared Add user-command handler: split args, expand vim tokens (% # <cfile> ~),
---gate on filereadable, parse an optional [start-line] [end-line] range, then send
---build_context_text(path, start, end) into the terminal. The only per-harness inputs are
---the command name, the notify prefix, and the harness's own build_context_text.
---@param cmd_name string e.g. "CopilotAdd" / "MakiAdd"
---@param harness string Notify prefix.
---@param type_into_terminal fun(text: string): number? The harness-bound send function.
---@param build_context_text fun(file_path: string, start_line?: integer, end_line?: integer): string
function M.make_add_command(cmd_name, harness, type_into_terminal, build_context_text)
  vim.api.nvim_create_user_command(cmd_name, function(opts)
    if not opts.args or opts.args == "" then
      vim.notify(harness .. ": no file path provided", vim.log.levels.WARN)
      return
    end
    local args = vim.split(opts.args, "%s+")
    local file_path = args[1]

    -- Expand vim tokens (% # <cfile> ...) and a leading ~; expand() leaves literal $ in
    -- paths intact, so TanStack-style $param files survive.
    if file_path:match("^[%%#<~]") then
      file_path = vim.fn.expand(file_path)
    end

    if vim.fn.filereadable(file_path) == 0 then
      vim.notify(harness .. ": not a readable file: " .. file_path, vim.log.levels.WARN)
      return
    end

    local start_line = args[2] and tonumber(args[2]) or nil
    local end_line = args[3] and tonumber(args[3]) or nil
    if start_line and end_line and start_line > end_line then
      vim.notify(harness .. ": start line must be <= end line", vim.log.levels.WARN)
      return
    end

    type_into_terminal(build_context_text(file_path, start_line, end_line))
  end, { nargs = "+", complete = "file" })
end

---Build the shared visual-selection sender: in visual mode send the selected lines (path +
---#L range), in normal mode send the whole buffer. Exits visual first so the '< / '> marks
---are set to the true selection bounds, then sends build_context_text accordingly.
---@param type_into_terminal fun(text: string): number? The harness-bound send function.
---@param build_context_text fun(file_path: string, start_line?: integer, end_line?: integer): string
---@return fun() The keymap callback (mode-agnostic; reads vim.fn.mode() at call time).
function M.send_visual_selection(type_into_terminal, build_context_text)
  return function()
    local file_path = vim.fn.expand("%:p")
    local mode = vim.fn.mode()

    if mode == "v" or mode == "V" or mode == "\22" then
      local anchor_line = vim.fn.line("v")
      local cursor_line = vim.fn.line(".")
      local start_line = math.min(anchor_line, cursor_line)
      local end_line = math.max(anchor_line, cursor_line)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      type_into_terminal(build_context_text(file_path, start_line, end_line))
      return
    end

    -- Normal mode: the whole buffer.
    type_into_terminal(build_context_text(file_path))
  end
end

return M
