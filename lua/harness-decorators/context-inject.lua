-- Shared helpers for typing path references into a harness terminal.
local windows = require("harness-decorators.windows")
local M = {}

---Return the first visible terminal window in the current tab. Several harness floats can be
---open, so this may not be the caller's harness.
---@return number? Window ID or nil if not running
function M.find_terminal_win()
  return windows.find(function(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == "terminal"
  end, { visible = true })
end

---Shorten a path for display in the harness terminal. Delegates to the shared definition in
---utils.shorten_path (~ collapse under $HOME, then full absolute). The per-harness @/range/
---decor is applied by each keymaps file on top of this result.
---@param file_path string
---@return string
function M.shorten_path(file_path)
  return require("harness-decorators.utils").shorten_path(file_path)
end

---Line-range suffix for a path reference.
---@param start_line? integer
---@param end_line? integer
---@return string "" without both bounds, "#L5" for one line, "#L5-9" for a span
function M.line_range(start_line, end_line)
  if not (start_line and end_line) then
    return ""
  end
  return start_line == end_line and ("#L" .. start_line) or ("#L" .. start_line .. "-" .. end_line)
end

---Path mention for the harness: "@" plus the path, a trailing slash for directories, and an optional
---#L range.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
function M.at_mention(file_path, start_line, end_line)
  local short = M.shorten_path(file_path)
  if vim.fn.isdirectory(file_path) == 1 and not short:match("/$") then
    short = short .. "/"
  end
  return "@" .. short .. M.line_range(start_line, end_line)
end

---Write text into the harness terminal's PTY via chansend. Multi-line text is wrapped in
---bracketed-paste markers so newlines arrive as one literal block. Never auto-submits.
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

  local term = require("harness-decorators.term")
  ---This harness's own visible window, or any terminal window when the harness has no float.
  local function target_win()
    local buf = term.bufnr(harness)
    if not buf then
      return M.find_terminal_win()
    end
    return windows.find(function(win)
      return vim.api.nvim_win_get_buf(win) == buf
    end, { visible = true })
  end

  local win = target_win()
  if not win then
    -- Open or re-show this harness's float.
    term.open(harness)
    win = target_win()
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

  if separate_space and not normalized:match("[%s ]$") then
    local ok_space, space_written = pcall(vim.fn.chansend, chan, " ")
    if not ok_space or space_written == 0 then
      vim.notify(harness .. ": failed to add spacing after file reference", vim.log.levels.WARN)
      return nil
    end
  end

  -- Leave visual mode before switching windows; otherwise the cursor lands at '> and corrupts the
  -- selection used by later context sends.
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

---Register a harness's Add/TreeAdd commands and return its per-key entries for
---harness-decorators/keymaps.lua. Each <harness>/keymaps.lua is one call to this.
---@param opts table
---  harness string: the harness name, e.g. "claude". Command names are derived from it ("ClaudeAdd").
---  format fun(file_path: string, start_line?: integer, end_line?: integer): string: how this
---    harness writes a path reference.
---  separate_space? boolean: send the trailing space as its own PTY write (see type_into_terminal).
---  add? boolean: declare <Harness>Add, <leader>ca in normal mode and the visual-mode <leader>ca.
---  history? boolean: declare <leader>cu.
---  resume? boolean: declare <leader>cr (opens the float with --resume).
---@return table[] keymap specs
function M.harness_keymaps(opts)
  local harness = opts.harness
  local keymaps = require("harness-decorators.keymaps")
  local name = require("harness-decorators.utils").capitalize(harness)

  local function send(text)
    return M.type_into_terminal(text, opts.separate_space and { separate_space = true } or nil, harness)
  end

  M.make_tree_add_command(name .. "TreeAdd", harness, send, opts.format)

  local specs = { keymaps.continue_spec(harness) }
  if opts.resume then
    table.insert(specs, {
      "<leader>cr",
      function()
        require("harness-decorators.term").open(harness, { args = "--resume" })
      end,
      desc = "Resume " .. name,
    })
  end
  if opts.history then
    table.insert(specs, keymaps.history_spec(harness))
  end
  if opts.add then
    M.make_add_command(name .. "Add", harness, send, opts.format)
    table.insert(specs, { "<leader>ca", "<cmd>" .. name .. "Add %<cr>", desc = "Add current buffer" })
    table.insert(specs, {
      "<leader>ca",
      M.send_visual_selection(send, opts.format),
      mode = "v",
      desc = (harness == "claude" and "Send to " or "Send selection to ") .. name,
    })
  end
  table.insert(specs, keymaps.tree_add_spec(harness, name .. "TreeAdd"))
  return specs
end

return M
