local sidecar = require("claude-decorators.sidecar")
local utils = require("claude-decorators.utils")

local M = {}

---Dedicated window next to the floating terminal for Claude Code edits.
M.jump_win = nil

---Edit sources keyed by session ID. Each value is a list of records.
M.edit_sources = {}

---Check if the currently focused window is a terminal buffer (the Claude terminal).
local function is_terminal_focused()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_buf_get_option(buf, "buftype") == "terminal"
end

---Find a non-float window with a real file buffer.
local function find_adjacent_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    local cfg = vim.api.nvim_win_get_config(win_id)
    -- config.relative is "" for normal windows, non-empty for floats.
    if cfg.relative ~= "" then goto continue end
    local buf = vim.api.nvim_win_get_buf(win_id)
    local ok, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
    -- Skip terminal, nofile, help, etc. — only normal file buffers.
    if ok and bt ~= "" then goto continue end
    if vim.api.nvim_buf_get_name(buf) ~= "" then return win_id end
    ::continue::
  end
  return nil
end

---Get or validate the jump window. Reuses the existing non-float window
---next to the floating terminal — no new splits created.
local function get_jump_win()
  if M.jump_win and not vim.api.nvim_win_is_valid(M.jump_win) then
    M.jump_win = nil
  end

  if not M.jump_win then
    M.jump_win = find_adjacent_window()
  end

  return M.jump_win
end

---Perform the actual jump logic (called inside defer_fn).
local function jump_to_edit(data, file_path)
  local win = get_jump_win()
  if not win then
    return
  end

  local line = data.starting_line and tonumber(data.starting_line)

  -- Load the buffer without switching the active window or touching terminal mode.
  -- bufadd creates the buffer entry; bufload reads the file (fires BufRead/BufReadPost
  -- for filetype/syntax/LSP setup). Neither changes the current window.
  local bufnr = vim.fn.bufadd(file_path)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  -- Switch the target window to show this buffer. Suppress autocmds during the switch:
  -- bufload() already fired BufRead/BufReadPost for filetype/LSP, so we don't need them
  -- here, and BufLeave/BufWinEnter from plugins have been observed to exit terminal insert
  -- mode as a side effect, creating a gap where keystrokes trigger normal-mode keybinds.
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = "all"
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.o.eventignore = saved_ei

  -- Defer cursor set so we run after any plugin BufWinEnter callbacks that restore
  -- the last-known cursor position and would otherwise override us.
  if line then
    vim.defer_fn(function()
      if not vim.api.nvim_win_is_valid(win) then return end
      local max_line = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, max_line)), 0 })
      if is_terminal_focused() then
        vim.cmd.startinsert()
      end
    end, 100)
  end
end

---Store an edit source record. Skips incomplete events, deduplicates in-place.
---Records are grouped by session ID, so switching sessions doesn't pollute
---the history of the previous one. Sidecar path is derived from the session
---ID at storage time and cached on the record for later Telescope lookup.
---@param data table from autocmd args.data
local function store_edit_source(data)
  local file_path = data.file_path
  local jsonl_path = data.jsonl_path
  local source_line = data.source_line
  local starting_line = data.starting_line
  local operation = data.operation or "Edit"
  local event_uuid = data.event_uuid
  local event_timestamp = data.event_timestamp
  local event_id = data.event_id

  -- Skip incomplete events: file_path is required.
  if not file_path then
    return
  end

  -- Generate timestamp on arrival (epoch-ms via os.time).
  local timestamp = os.time() * 1000

  local session_id = utils.extract_session_id(jsonl_path)
  if not session_id then
    return
  end

  local sidecar_path = sidecar.path(session_id)

  local new_record = {
    timestamp = timestamp,
    time_str = utils.format_time(timestamp),
    file_path = file_path,
    source_line = source_line,
    starting_line = starting_line,
    operation = operation,
    event_uuid = event_uuid,
    event_timestamp = event_timestamp,
    event_id = event_id,
    sidecar_path = sidecar_path,
  }

  local list = M.edit_sources[session_id]
  if not list then
    list = {}
    M.edit_sources[session_id] = list
  end

  -- Dedup / skip logic for same-file events arriving close together:
  --   1. Last has starting_line, new doesn't → drop new (incomplete).
  --   2. Last missing starting_line, new has one → replace last in-place
  --      with the better record.
  --   3. Both missing starting_line → replace last in-place (duplicate).
  local last = list[#list]
  if last and last.file_path == file_path then
    local time_diff = math.abs(last.timestamp - timestamp)
    if time_diff < 5000 then -- within 5 seconds = same edit
      if last.starting_line and not starting_line then
        return -- prefer the record that already has a line number
      end
      if starting_line or (not last.source_line and not source_line) then
        list[#list] = new_record -- upgrade or dedup
        return
      end
    end
  end

  table.insert(list, new_record)
end

---Jump to the edited file without stealing focus from the terminal.
function M.on_edit(args)
  if not args.data then
    return
  end
  local file_path = args.data.file_path
  if type(file_path) ~= "string" or #file_path == 0 then
    return
  end

  store_edit_source(args.data)

  vim.defer_fn(function()
    -- Skip jumping if focus is not on the Claude terminal.
    if not is_terminal_focused() then
      return
    end
    jump_to_edit(args.data, file_path)
  end, 500)
end

---Callback for ClaudeCodeDiffClosed autocmd.
function M.on_diff_closed(args)
  if not args.data or not args.data.reason then
    return
  end
  if not args.data.reason:find("save") then
    return
  end
  if not is_terminal_focused() then
    return
  end
  M.on_edit(args)
end

---Create the autocmds that trigger jump behavior. Call from init setup.
function M.create_jump_autocmds(group)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeCodeDiffClosed",
    callback = M.on_diff_closed,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeAutoFollowEdit",
    callback = M.on_edit,
  })

end

return M
