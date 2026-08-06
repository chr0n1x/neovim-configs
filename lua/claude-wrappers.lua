-- Custom wrappers and hooks for claudecode.nvim
-- Extends the plugin with auto-follow behavior for automode edits
--
-- Detection strategy: inotifywait watches ~/.claude/projects/ recursively.
-- On CLOSE_WRITE of a .jsonl file, read the last line and check for
-- toolUseResult (completed tool execution). Fire ClaudeAutoFollowEdit
-- so the on_edit handler can jump to the modified file.

local M = {}

---Session pin state: which JSONL session matches the visible terminal.
M.pinned_jsonl_path = nil        -- path of the JSONL currently matched to terminal

---Inotify watcher state.
M.inotify_handle = nil
M.inotify_log = nil              -- temp file that inotifywait appends to
M.inotify_last_pos = 0           -- file position we last read to
M.inotify_poll_timer = nil       -- lightweight timer to check for new inotify output

---Rate-limited logger: suppresses duplicate message prefixes within a cooldown window.
local log_cooldown_ms = 3000     -- 3 seconds between identical-ish messages
local log_seen = {}              -- [msg_prefix] = timestamp
local function log_message(msg, level)
  if not msg then return end
  local now = math.floor(vim.uv.hrtime() / 1000000)
  local key = msg:sub(1, 40)     -- dedup key: first 40 chars
  local last = log_seen[key]
  if last and now - last < log_cooldown_ms then
    return
  end
  log_seen[key] = now
  vim.notify("[claude.nvim auto-follow] " .. msg, level or vim.log.levels.INFO)
end

-- ==========================================================================
-- LEGACY FALLBACK STUBS
-- ==========================================================================
-- Stubs used when inotifywait is unavailable. Defined early for forward refs.
local poll_timer = nil

local function start_watch()
  if poll_timer then return end
  log_message("polling fallback activated (inotifywait unavailable)", vim.log.levels.WARN)
end

local function stop_watch()
  if poll_timer then
    pcall(function() poll_timer:stop() end)
    pcall(function() poll_timer:close() end)
    poll_timer = nil
  end
end

-- ==========================================================================
-- INOTIFYWAIT-DRIVEN JSONL WATCHER
-- ==========================================================================

---@diagnostic disable-next-line:unused-local
local FILE_TOOLS = {
  Write = true,
  Edit = true,
  Update = true,
  NotebookEdit = true,
}

---Check if a file path is noise (temp/swap files).
local function is_noise(file_path)
  if type(file_path) ~= "string" or #file_path == 0 then return true end
  return file_path:match("%.tmp%d*$")
    or file_path:match("%.sw[npx]$")
    or file_path:match("~$")
    or file_path:match("^/proc/")
end

---Read the last `bytes` bytes of a file. Returns the tail string or nil.
local function read_file_tail(path, bytes)
  if not path then return nil end
  bytes = bytes or 8192
  local f = io.open(path, "r")
  if not f then return nil end
  local stat = f:seek("end")
  if stat == 0 then
    f:close()
    return nil
  end
  local pos = math.max(1, stat - bytes)
  f:seek("set", pos)
  local tail = f:read("*a")
  f:close()
  return tail or nil
end

---Read the last non-empty line of a file. Returns nil on failure.
local function read_last_line(path)
  local tail = read_file_tail(path, 8192)
  if not tail or #tail == 0 then return nil end

  local lines = {}
  for line in tail:gmatch("([^\r\n]*)\r?\n?") do
    if #line > 0 then lines[#lines + 1] = line end
  end
  return lines[#lines] or nil
end

---Pin to a JSONL session. Uses inotify event source as the signal —
---whichever JSONL is receiving writes is the active session.
---Returns true if pinned successfully.
local function try_pin_session(jsonl_path)
  -- Already pinned to this session — skip.
  if M.pinned_jsonl_path == jsonl_path then
    return true
  end
  M.pinned_jsonl_path = jsonl_path
  local stripped_path = jsonl_path:match("[^/]+$")
  log_message("session detected " .. stripped_path, vim.log.levels.INFO)
  return true
end

---Parse a toolUseResult from a JSONL user-type entry.
---Returns change_info table or nil.
local function parse_tool_result(line)
  -- Quick pre-filter: only parse lines that look like tool results.
  if not line:find('"toolUseResult"') then return end
  if not line:find('"type":"user"') then return end

  local ok, entry = pcall(vim.json.decode, line)
  if not ok or not entry then return end

  local tur = entry.toolUseResult
  if not tur then return end

  local fp = tur.filePath
  if not fp or is_noise(fp) then return end

  -- Determine operation from oldString/newString vs structuredPatch.
  local operation = "Edit" -- default
  if tur.oldString and tur.newString then
    operation = "Edit"
  elseif tur.structuredPatch then
    operation = "Edit"
  end

  -- Extract starting line from structuredPatch.
  local starting_line = nil
  if tur.structuredPatch and tur.structuredPatch[1] then
    starting_line = tur.structuredPatch[1].newStart
    or tur.structuredPatch[1].oldStart
  end

  -- Build a delta string for logging.
  local delta = ""
  if tur.oldString and tur.newString then
    delta = tur.newString:gsub("\n", "\\n"):sub(1, 60)
  elseif tur.structuredPatch and tur.structuredPatch[1] then
    local sp = tur.structuredPatch[1]
    delta = string.format("%d->%d lines", sp.oldLines or 0, sp.newLines or 0)
  end

  return {
    file_path = fp,
    operation = operation,
    starting_line = starting_line,
    delta = delta,
    -- Use uuid + timestamp as a unique dedup key.
    dedup_key = entry.uuid and (entry.uuid .. entry.timestamp) or nil,
  }
end

---Handle an inotify event line: "<dir> <events> <filename>".
local function on_inotify_event(raw_line)
  if not raw_line or #raw_line == 0 then return end

  -- inotifywait format: "/path/to/dir/ CLOSE_WRITE filename"
  local dir, _, filename = raw_line:match("^(.-)%s+(.-)%s+(.+)$")
  if not dir or not filename then return end

  -- Only process .jsonl files.
  if not filename:match("%.jsonl$") then return end

  -- Skip subagent directories — we only care about root session JSONLs.
  if dir:find("/subagents/") then return end

  -- Strip trailing slash from dir.
  dir = dir:gsub("/+$", "")
  local jsonl_path = dir .. "/" .. filename

  --- Session pin logic ---------------------------------------------------
  -- Case 1: Event is from the pinned JSONL — process immediately.
  if jsonl_path == M.pinned_jsonl_path then
    -- Process (fall through below).
  elseif not M.pinned_jsonl_path then
    -- Case 2: No pin yet — pin to this session.
    log_message("no active pin, trying to pin " .. filename, vim.log.levels.DEBUG)
    if not try_pin_session(jsonl_path) then
      return
    end
  else
    -- Case 3: Event from different JSONL — session switch.
    -- New JSONL getting writes = new active session. Re-pin.
    log_message("session switch detected, re-pin to " .. filename, vim.log.levels.DEBUG)
    M.pinned_jsonl_path = nil
    if not try_pin_session(jsonl_path) then
      return
    end
  end

  --- Tool result processing -----------------------------------------------
  local last_line = read_last_line(jsonl_path)
  if not last_line then return end

  local change_info = parse_tool_result(last_line)
  if not change_info then return end

  -- Dedup check.
  local dedup_key = change_info.dedup_key
  if dedup_key then
    local seen = M.tool_at_key_seen(dedup_key)
    if seen then
      log_message(
        "NOT firing autocmd; SEEN " .. dedup_key:sub(1, 8),
        vim.log.levels.DEBUG
      )
      return
    end
    M.mark_key_seen(dedup_key)
  end

  local line_str = change_info.starting_line and ":" .. change_info.starting_line or ""
  log_message(
    "detected edit @ " .. change_info.file_path .. line_str
  )

  log_message(
    "firing autocmd ClaudeAutoFollowEdit @ " .. change_info.file_path .. line_str,
    vim.log.levels.DEBUG
  )

  vim.api.nvim_exec_autocmds("User", {
    pattern = "ClaudeAutoFollowEdit",
    data = change_info,
  })
end

---Process new lines appended to the inotify log file since last read.
local function process_inotify_log()
  if not M.inotify_log then return end

  local f = io.open(M.inotify_log, "r")
  if not f then return end

  local stat = f:seek("end")
  if stat <= M.inotify_last_pos then
    f:close()
    return
  end

  -- File grew. If it grew too much, reset to avoid reading megabytes.
  if stat - M.inotify_last_pos > 65536 then
    M.inotify_last_pos = stat
    f:close()
    return
  end

  f:seek("set", M.inotify_last_pos)
  local chunk = f:read(stat - M.inotify_last_pos)
  M.inotify_last_pos = stat
  f:close()

  if not chunk then return end

  -- Split on newlines and process each complete line.
  for line in chunk:gmatch("([^\r\n]+)") do
    pcall(on_inotify_event, line)
  end
end

---Callback when inotifywait process exits.
local function on_inotify_exit(code)
  if M.inotify_handle then
    log_message(
      "inotifywait exited with code " .. tostring(code),
      vim.log.levels.WARN
    )
    M.inotify_handle = nil
  end
end

---Timer callback: process new inotify log entries.
local function on_inotify_poll()
  pcall(process_inotify_log)
end

---Start the inotifywait watcher process.
local function start_inotify_watch()
  if M.inotify_handle then return end

  -- Check if inotifywait is available.
  local check = io.popen("which inotifywait 2>/dev/null")
  if check then
    local path = check:read("*a"):gsub("%s+", "")
    check:close()
    if #path == 0 then
      log_message("inotifywait not found, falling back to polling", vim.log.levels.WARN)
      start_watch()
      return
    end
  else
    log_message("inotifywait not found, falling back to polling", vim.log.levels.WARN)
    start_watch()
    return
  end

  local projects_dir = os.getenv("HOME") .. "/.claude/projects"

  -- Check if directory exists.
  local f = io.open(projects_dir, "r")
  if not f then
    log_message("projects dir does not exist: " .. projects_dir, vim.log.levels.WARN)
    start_watch()
    return
  end
  f:close()

  -- Create a temp file for inotifywait to append to.
  local user = os.getenv("USER") or "kran"
  M.inotify_log = string.format("/tmp/nvim.%s.inotify.log", user)
  M.inotify_last_pos = 0

  -- Truncate any leftover log.
  local truncate = io.open(M.inotify_log, "w")
  if truncate then truncate:close() end

  local cmd = "bash"
  local args = {
    "-c", string.format(
      "inotifywait -m -r -e close_write --format '%%w %%e %%f' %s >> %s 2>/dev/null",
      vim.fn.shellescape(projects_dir),
      vim.fn.shellescape(M.inotify_log)
    ),
  }

  log_message("starting inotifywait on " .. projects_dir, vim.log.levels.INFO)

  -- Spawn as a background process.
  -- inotifywait appends output to inotify_log via shell redirection in the bash -c command.
  M.inotify_handle = vim.uv.spawn(cmd, { args = args }, on_inotify_exit)

  if not M.inotify_handle then
    log_message("failed to spawn inotifywait, falling back to polling", vim.log.levels.WARN)
    M.inotify_log = nil
    start_watch()
    return
  end

  -- Poll the inotify log file for new content.
  -- This is lightweight: just fs_stat + read delta, not a full buffer dump.
  M.inotify_poll_timer = vim.uv.new_timer()
  M.inotify_poll_timer:start(0, 500, vim.schedule_wrap(on_inotify_poll))
end

---Stop the inotifywait watcher process.
local function stop_inotify_watch()
  if M.inotify_handle then
    pcall(function() vim.uv.kill(M.inotify_handle, 15) end) -- SIGTERM
    pcall(function() M.inotify_handle:close() end)
    M.inotify_handle = nil
  end
  if M.inotify_poll_timer then
    pcall(function() M.inotify_poll_timer:stop() end)
    pcall(function() M.inotify_poll_timer:close() end)
    M.inotify_poll_timer = nil
  end
  -- Clean up the temp log file.
  if M.inotify_log then
    pcall(vim.fn.delete, M.inotify_log)
    M.inotify_log = nil
  end
end

-- ==========================================================================
-- EDIT JUMP HANDLER
-- ==========================================================================

---Jump to a line number if one is provided.
local function maybe_jump_to_line(starting_line)
  if starting_line then
    local line = tonumber(starting_line)
    if line then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
    end
  end
end

---Perform the actual jump logic (called inside defer_fn).
local function jump_to_edit(data, file_path)
  vim.cmd("checktime")

  -- Don't steal focus if the user is in the terminal.
  local cur_buf = vim.api.nvim_win_get_buf(0)
  if vim.bo[cur_buf].buftype == "terminal" then return end

  local bufnr = vim.fn.bufnr(file_path)

  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    -- Already loaded — jump to the window showing it.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then
        vim.api.nvim_set_current_win(w)
        maybe_jump_to_line(data.starting_line)
        return
      end
    end
  end

  -- Not loaded or not visible — open it in the first non-terminal window.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= "terminal" then
      vim.api.nvim_set_current_win(w)
      vim.cmd("edit " .. vim.fn.fnameescape(file_path))
      maybe_jump_to_line(data.starting_line)
      return
    end
  end
end

---Jump to the edited file without stealing focus from the terminal.
local function on_edit(args)
  if not args.data then return end
  local file_path = args.data.file_path
  if type(file_path) ~= "string" or #file_path == 0 then return end

  vim.defer_fn(function()
    jump_to_edit(args.data, file_path)
  end, 500)
end

-- ==========================================================================
-- DEDUP TRACKING
-- ==========================================================================

---Track seen dedup keys to avoid firing the same edit twice.
M.seen_keys = {}

M.tool_at_key_seen = function(key)
  if not key then return false end
  return M.seen_keys[key] ~= nil
end

M.mark_key_seen = function(key)
  if not key then return end
  M.seen_keys[key] = true
end

-- Legacy: kept for backwards compat, not used by inotify watcher.
M.tool_at_path_pos_seen = function(path, tool, pos)
  if not (path and tool and pos) then
    return false
  end
  M.tool_uses[path] = M.tool_uses[path] or {}
  M.tool_uses[path][tool] = M.tool_uses[path][tool] or {}
  return M.tool_uses[path][tool][pos] ~= nil
end

-- ==========================================================================
-- SETUP
-- ==========================================================================

---Callback for ClaudeCodeDiffClosed autocmd.
local function on_diff_closed(args)
  if not args.data or not args.data.reason then return end
  if not args.data.reason:find("save") then return end
  on_edit(args)
end

---Callback for VimLeavePre autocmd.
local function on_vim_leave()
  stop_inotify_watch()
  -- Legacy cleanup.
  stop_watch()
end

M.setup_auto_follow = function()
  local group = vim.api.nvim_create_augroup(
    "ClaudeAutoFollow",
    {
      clear = true
    }
  )

  -- Path 1: diff accepted (review mode).
  vim.api.nvim_create_autocmd(
    "User",
    {
      group = group,
      pattern = "ClaudeCodeDiffClosed",
      callback = on_diff_closed,
    }
  )

  -- Path 2: automode direct edits detected via inotifywait watcher.
  vim.api.nvim_create_autocmd(
    "User",
    {
      group = group,
      pattern = "ClaudeAutoFollowEdit",
      callback = on_edit,
    }
  )

  vim.api.nvim_create_autocmd(
    "VimLeavePre",
    {
      group = group,
      callback = on_vim_leave,
    }
  )

  M.seen_keys = {}
  M.tool_uses = {}
  M.pinned_jsonl_path = nil
  log_seen = {}
  start_inotify_watch()
end

M.setup = function()
  local ok, err = pcall(M.setup_auto_follow)
  if not ok then
    log_message("setup failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

return M
