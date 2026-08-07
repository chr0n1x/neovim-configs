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

---Find a non-float window with a real buffer (mirrors ai-claude.lua's find_base_window).
local function find_adjacent_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  -- Iterate reverse to get the window "next to" the floating terminal.
  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    local config = vim.api.nvim_win_get_config(win_id)
    local buf_info = vim.api.nvim_win_get_buf(win_id)
    local buf_name = vim.api.nvim_buf_get_name(buf_info)
    -- Skip floats and empty buffers.
    if not config.z and buf_name ~= "" then
      return win_id
    end
  end
  return nil
end

---Jump to a line number if one is provided.
local function maybe_jump_to_line(win, starting_line)
  if starting_line then
    local line = tonumber(starting_line)
    if line then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
    end
  end
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
  vim.cmd("checktime")

  local win = get_jump_win()
  if not win then return end

  -- Reload buffer if it exists and was modified externally.
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_win_set_buf(win, bufnr)
    maybe_jump_to_line(win, data.starting_line)
  else
    -- Use win_execute to avoid changing current window/tab.
    vim.api.nvim_win_call(win, function()
      vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    end)
    maybe_jump_to_line(win, data.starting_line)
  end
end

---Extract session ID from JSONL file path.
---@param jsonl_path string
---@return string|nil
local function extract_session_id(jsonl_path)
  if not jsonl_path then return end
  local session_id = jsonl_path:match("/([^/]+)%.jsonl$")
  if not session_id then
    session_id = jsonl_path:match("^([^/]+)%.jsonl$")
  end
  return session_id or nil
end

---Format epoch-ms as human-readable date string.
---@param ts number epoch milliseconds
---@return string
local function format_time(ts)
  local secs = math.floor(ts / 1000)
  return os.date("%Y-%m-%d %H:%M:%S", secs)
end

---Store an edit source record. Skips incomplete events, deduplicates in-place.
---@param data table from autocmd args.data
local function store_edit_source(data)
  local file_path = data.file_path
  local jsonl_path = data.jsonl_path
  local source_line = data.source_line
  local operation = data.operation or "Edit"

  -- Skip incomplete events: file_path is required.
  if not file_path then return end

  -- Generate timestamp on arrival (epoch-ms via os.time).
  local timestamp = os.time() * 1000

  local session_id = extract_session_id(jsonl_path)
  if not session_id then return end

  local new_record = {
    timestamp = timestamp,
    time_str = format_time(timestamp),
    file_path = file_path,
    source_line = source_line,
    operation = operation,
  }

  local list = M.edit_sources[session_id]
  if not list then
    list = {}
    M.edit_sources[session_id] = list
  end

  -- In-place dedup: if the latest record for this session shares the same
  -- file_path, has no source_line, and its timestamp is within ~100ms,
  -- replace it in-place instead of appending.
  local last = list[#list]
  if last
    and last.file_path == file_path
    and not last.source_line
    and math.abs(last.timestamp - timestamp) < 100
  then
    list[#list] = new_record
    return
  end

  table.insert(list, new_record)
end

---Jump to the edited file without stealing focus from the terminal.
function M.on_edit(args)
  if not args.data then return end
  local file_path = args.data.file_path
  if type(file_path) ~= "string" or #file_path == 0 then return end

  store_edit_source(args.data)

  vim.defer_fn(function()
    -- Skip jumping if focus is not on the Claude terminal.
    if not is_terminal_focused() then return end
    jump_to_edit(args.data, file_path)
  end, 500)
end

---Callback for ClaudeCodeDiffClosed autocmd.
function M.on_diff_closed(args)
  if not args.data or not args.data.reason then return end
  if not args.data.reason:find("save") then return end
  if not is_terminal_focused() then return end
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
