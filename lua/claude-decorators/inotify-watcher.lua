local utils = require("claude-decorators.utils")
local parser = require("claude-decorators.jsonl-parser")
local sidecar = require("claude-decorators.sidecar")
local edit_jump = require("claude-decorators.edit-jump")

local M = {}

---Session pin state: which JSONL session matches the visible terminal.
M.pinned_jsonl_path = nil

---JSONL paths confirmed to NOT belong to this Neovim's Claude session.
M.ignored_jsonl_paths = {}

---CWD of this Neovim instance, set at startup.
M.nvim_cwd = nil

---Append a raw JSONL line to the sidecar file for the current pinned session.
local function append_sidecar(raw_line)
  local sp = sidecar.path_from_jsonl(M.pinned_jsonl_path)
  sidecar.append(sp, raw_line)
end

---Watcher state. Backend is "inotifywait" or "fswatch", whichever was found.
M.inotify_handle = nil
M.inotify_pid = nil
M.watcher_backend = nil
M.inotify_log = nil
M.inotify_last_pos = 0
M.inotify_poll_timer = nil

---Track read position per JSONL session so we can scan new lines on each event.
---Each value is { byte_pos, line_count } — byte offset and the number of lines
---scanned up to that point, so we know the absolute line number of new content.
local jsonl_positions = {}

---Pending notification handles keyed by file path, so we can update them
---when the more complete toolUseResult arrives.
local pending_notifications = {}

--- Terminal buffer text cache (1s TTL) to avoid re-reading on every write event.
local TERM_CACHE_TTL_SECS = 1
local _term_cache = { text = nil, expires = 0 }

---Return concatenated Claude terminal buffer lines, cached for TERM_CACHE_TTL_SECS.
---Must run on the main thread (Vim API access).
---@return string
local function get_terminal_text()
  local now = os.time()
  if _term_cache.text and now < _term_cache.expires then
    return _term_cache.text
  end

  ---@type string
  local text = ""
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ok, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
    if ok and bt == "terminal" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find("claude", 1, true) then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        text = table.concat(lines, "\n")
        break
      end
    end
  end

  _term_cache = { text = text, expires = now + TERM_CACHE_TTL_SECS }
  return text
end

---Return true if any message in `typed_messages` appears in the Claude terminal buffer.
---Uses a 50-char prefix fingerprint because the terminal truncates long lines.
local function matches_terminal(typed_messages)
  local term_text = get_terminal_text()
  if #term_text == 0 then
    return false
  end
  for _, msg in ipairs(typed_messages) do
    local fingerprint = msg:sub(1, 50)
    if term_text:find(fingerprint, 1, true) then
      return true
    end
  end
  return false
end

---Extract the cwd from the first parseable JSONL line that has it.
local function extract_cwd(lines)
  for _, line in ipairs(lines) do
    if line:find('"cwd"') then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.cwd then
        return entry.cwd
      end
    end
  end
  return nil
end

---Extract typed user message texts from JSONL lines.
---Only returns messages with string content >= 20 chars to avoid false positives.
local function extract_typed_messages(lines)
  local msgs = {}
  for _, line in ipairs(lines) do
    if line:find('"promptSource"') and line:find('"typed"') then
      local ok, entry = pcall(vim.json.decode, line)
      if
        ok
        and entry
        and entry.type == "user"
        and entry.promptSource == "typed"
        and entry.message
        and type(entry.message.content) == "string"
        and #entry.message.content >= 20
      then
        msgs[#msgs + 1] = entry.message.content
      end
    end
  end
  return msgs
end

---Return true if a typed message content is a session-resetting slash command.
local function is_reset_command(content)
  local trimmed = content:match("^%s*(.-)%s*$")
  return trimmed == "/resume" or trimmed == "/clear" or trimmed == "/new"
end

---Determine session ownership from a set of JSONL lines.
---Returns "match" (this is our session), "mismatch" (definitely not), or
---"unknown" (no typed messages long enough to compare).
local function session_ownership(lines)
  -- Quick cwd pre-filter: any line with a mismatched cwd rules this out immediately.
  if M.nvim_cwd then
    local cwd = extract_cwd(lines)
    if cwd and cwd ~= M.nvim_cwd then
      return "mismatch"
    end
  end

  local typed = extract_typed_messages(lines)
  if #typed == 0 then
    return "unknown"
  end

  return matches_terminal(typed) and "match" or "mismatch"
end

---Clear all per-session state and fire the reset for the given session ID.
---Call on /resume, /clear, or re-pin so the history picker starts fresh.
---jsonl_positions is intentionally NOT cleared: keeping byte offsets avoids a
---missed-write-batch immediately after re-pin.
local function reset_session_state(old_session_id)
  if old_session_id then
    edit_jump.edit_sources[old_session_id] = nil
  end
  M.pinned_jsonl_path = nil
  M.ignored_jsonl_paths = {}
  pending_notifications = {}
  _term_cache = { text = nil, expires = 0 }
end

---Pin to a JSONL session.
local function try_pin_session(jsonl_path)
  if M.pinned_jsonl_path == jsonl_path then
    return true
  end
  -- If re-pinning to a different session, clear the old session's history.
  local old_session_id = utils.extract_session_id(M.pinned_jsonl_path)
  if old_session_id then
    utils.log("re-pin: clearing history for old session " .. old_session_id:sub(1, 8), vim.log.levels.DEBUG)
  end
  reset_session_state(old_session_id)

  M.pinned_jsonl_path = jsonl_path
  local name = jsonl_path:match("([^/]+)%.jsonl$") or jsonl_path:match("[^/]+$")
  utils.log("session detected " .. name, vim.log.levels.INFO)
  return true
end

---Parse an inotifywait log line: "<dir> <events> <filename>".
---Returns the full jsonl path, or nil if the line should be ignored.
local function parse_inotify_line(raw_line)
  if not raw_line or #raw_line == 0 then
    return nil
  end

  -- inotifywait format: "/path/to/dir/ CLOSE_WRITE filename"
  local dir, _, filename = raw_line:match("^(.-)%s+(.-)%s+(.+)$")
  if not dir or not filename then
    return nil
  end

  -- Only process .jsonl files.
  if not filename:match("%.jsonl$") then
    return nil
  end

  -- Skip subagent directories — we only care about root session JSONLs.
  if dir:find("/subagents/") then
    return nil
  end

  -- Strip trailing slash from dir.
  dir = dir:gsub("/+$", "")
  return dir .. "/" .. filename
end

---Parse an fswatch log line: a bare absolute path, one per line (fswatch's
---default output format when no --format/-x flags are given).
---Returns the full jsonl path, or nil if the line should be ignored.
local function parse_fswatch_line(raw_line)
  if not raw_line or #raw_line == 0 then
    return nil
  end

  local jsonl_path = raw_line:match("^%s*(.-)%s*$")
  if not jsonl_path:match("%.jsonl$") then
    return nil
  end
  if jsonl_path:find("/subagents/") then
    return nil
  end

  return jsonl_path
end

---Handle a confirmed JSONL write: identify session ownership, then scan new lines.
local function process_jsonl_write(jsonl_path)
  local filename = jsonl_path:match("[^/]+$")

  -- Fast reject: path confirmed to belong to a different session.
  if M.ignored_jsonl_paths[jsonl_path] then
    return
  end

  --- Read new content -------------------------------------------------------
  local f = io.open(jsonl_path, "r")
  if not f then
    return
  end
  local file_size = f:seek("end")
  f:close()

  local prev = jsonl_positions[jsonl_path]

  -- First encounter: read the file tail for session identification, then set baseline.
  if prev == nil then
    jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }

    -- Read tail for session ownership check (don't process tool results from old content).
    local tail = parser.read_tail(jsonl_path, 8192)
    if tail and #tail > 0 then
      local tail_lines = {}
      for line in tail:gmatch("([^\r\n]+)") do
        tail_lines[#tail_lines + 1] = line
      end

      if not M.pinned_jsonl_path then
        local ownership = session_ownership(tail_lines)
        if ownership == "match" then
          utils.log("initial pin to " .. filename, vim.log.levels.DEBUG)
          try_pin_session(jsonl_path)
        elseif ownership == "mismatch" then
          utils.log("ignoring non-matching session " .. filename, vim.log.levels.DEBUG)
          M.ignored_jsonl_paths[jsonl_path] = true
        end
        -- "unknown": no typed messages yet, leave as candidate
      end
    end
    return
  end

  if file_size <= prev.byte_pos then
    return
  end

  local chunk_file = io.open(jsonl_path, "r")
  if not chunk_file then
    return
  end
  chunk_file:seek("set", prev.byte_pos)
  local chunk = chunk_file:read(file_size - prev.byte_pos)
  chunk_file:close()

  if not chunk then
    return
  end

  local lines = {}
  for line in chunk:gmatch("([^\r\n]+)") do
    lines[#lines + 1] = line
  end

  local prev_line_count = prev.line_count or 0
  local chunk_start_line = prev_line_count + 1
  jsonl_positions[jsonl_path] = {
    byte_pos = file_size,
    line_count = prev_line_count + #lines,
  }

  -- test edit at line 302
  --- Session pin logic -------------------------------------------------------
  if not M.pinned_jsonl_path then
    local ownership = session_ownership(lines)
    if ownership == "match" then
      utils.log("no active pin, pinning " .. filename, vim.log.levels.DEBUG)
      try_pin_session(jsonl_path)
    elseif ownership == "mismatch" then
      utils.log("ignoring non-matching session " .. filename, vim.log.levels.DEBUG)
      M.ignored_jsonl_paths[jsonl_path] = true
      return
    else
      -- "unknown": no typed messages yet, keep as candidate
      return
    end
  elseif jsonl_path ~= M.pinned_jsonl_path then
    local ownership = session_ownership(lines)
    if ownership == "match" then
      utils.log("session switch, re-pinning to " .. filename, vim.log.levels.DEBUG)
      try_pin_session(jsonl_path) -- resets state, sets new pin
    elseif ownership == "mismatch" then
      utils.log("ignoring write from non-matching session " .. filename, vim.log.levels.DEBUG)
      M.ignored_jsonl_paths[jsonl_path] = true
      return
    else
      return
    end
  end

  --- Pinned session: check for reset commands and process tool results --------
  for i, line in ipairs(lines) do
    -- Detect /resume, /clear, /new: reset session state.
    if line:find('"promptSource"') and line:find('"typed"') then
      local ok, entry = pcall(vim.json.decode, line)
      if
        ok
        and entry
        and entry.type == "user"
        and entry.promptSource == "typed"
        and entry.message
        and type(entry.message.content) == "string"
        and is_reset_command(entry.message.content)
      then
        local cmd = entry.message.content:match("^%s*(.-)%s*$")
        local old_sid = utils.extract_session_id(M.pinned_jsonl_path)
        utils.log("reset command " .. cmd .. " detected; clearing session state", vim.log.levels.INFO)
        if cmd == "/clear" then
          -- Same JSONL continues — only clear history, keep the pin.
          if old_sid then
            edit_jump.edit_sources[old_sid] = nil
          end
          M.ignored_jsonl_paths = {}
          pending_notifications = {}
          _term_cache = { text = nil, expires = 0 }
        else
          -- /resume or /new: session will switch to a different JSONL.
          reset_session_state(old_sid)
        end
        return
      end
    end

    local change_info = parser.parse_tool_result(line, chunk_start_line + i - 1)
    if change_info then
      append_sidecar(line)

      local dedup_key = change_info.dedup_key
      if dedup_key and utils.key_seen(dedup_key) then
        utils.log("NOT firing autocmd; SEEN " .. dedup_key:sub(1, 8), vim.log.levels.DEBUG)
      else
        if dedup_key then
          utils.mark_key_seen(dedup_key)
        end

        local fp = change_info.file_path
        local line_str = change_info.starting_line and ":" .. change_info.starting_line or ""

        if change_info.starting_line then
          if pending_notifications[fp] then
            utils.log(fp .. line_str, vim.log.levels.INFO, { replace = pending_notifications[fp] })
            pending_notifications[fp] = nil
          else
            utils.log(fp .. line_str)
          end
          utils.log("firing autocmd ClaudeAutoFollowEdit @ " .. fp .. line_str, vim.log.levels.DEBUG)
        else
          local handle = utils.log(fp, vim.log.levels.INFO)
          pending_notifications[fp] = handle
          utils.log("early tool_use @ " .. fp, vim.log.levels.DEBUG)
        end

        vim.api.nvim_exec_autocmds("User", {
          pattern = "ClaudeAutoFollowEdit",
          data = {
            file_path = change_info.file_path,
            operation = change_info.operation,
            starting_line = change_info.starting_line,
            delta = change_info.delta,
            source_line = change_info.source_line,
            jsonl_path = M.pinned_jsonl_path,
            event_uuid = change_info.event_uuid,
            event_timestamp = change_info.event_timestamp,
            event_id = change_info.event_id,
          },
        })
      end
    end
  end
end

---Process new lines appended to the watcher log file since last read.
local function process_inotify_log()
  if not M.inotify_log then
    return
  end

  local f = io.open(M.inotify_log, "r")
  if not f then
    return
  end

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

  if not chunk then
    return
  end

  local parse_line = M.watcher_backend == "fswatch" and parse_fswatch_line or parse_inotify_line

  for line in chunk:gmatch("([^\r\n]+)") do
    local ok, jsonl_path = pcall(parse_line, line)
    if ok and jsonl_path then
      pcall(process_jsonl_write, jsonl_path)
    end
  end
end

---Callback when the watcher process exits.
local function on_inotify_exit(code)
  if M.inotify_handle then
    utils.log((M.watcher_backend or "watcher") .. " exited with code " .. tostring(code), vim.log.levels.WARN)
    M.inotify_handle = nil
  end
end

---Timer callback: process new watcher log entries.
local function on_inotify_poll()
  pcall(process_inotify_log)
end

---Return the resolved path of `bin` if it's on $PATH, else nil.
local function which(bin)
  local check = io.popen("command -v " .. bin .. " 2>/dev/null")
  if not check then
    return nil
  end
  local path = check:read("*a"):gsub("%s+", "")
  check:close()
  if #path == 0 then
    return nil
  end
  return path
end

---Spawn inotifywait, writing its own output to `log_path` via --outfile.
local function spawn_inotifywait(projects_dir, log_path)
  return vim.uv.spawn("inotifywait", {
    args = {
      "-m",
      "-r",
      "-e",
      "close_write",
      "--format",
      "%w %e %f",
      projects_dir,
      "--outfile",
      log_path,
    },
  }, on_inotify_exit)
end

---Spawn fswatch, redirecting its stdout (bare path per line) to `log_path`.
local function spawn_fswatch(projects_dir, log_path)
  local fd = vim.uv.fs_open(log_path, "w", tonumber("644", 8))
  if not fd then
    return nil
  end

  local handle, pid = vim.uv.spawn("fswatch", {
    args = { "-r", "-l", "0.3", "--event", "Updated", projects_dir },
    stdio = { nil, fd, nil },
  }, on_inotify_exit)

  vim.uv.fs_close(fd)
  return handle, pid
end

---Best-effort: try inotifywait, then fswatch, then give up without ever
---starting a polling fallback.
function M.start()
  if M.inotify_handle then
    return
  end

  local backend = which("inotifywait") and "inotifywait" or (which("fswatch") and "fswatch")
  if not backend then
    utils.log("neither inotifywait nor fswatch found; live JSONL following disabled", vim.log.levels.WARN)
    return
  end

  local projects_dir = os.getenv("HOME") .. "/.claude/projects"

  -- Check if directory exists.
  local f = io.open(projects_dir, "r")
  if not f then
    utils.log("projects dir does not exist: " .. projects_dir, vim.log.levels.WARN)
    return
  end
  f:close()

  local user = os.getenv("USER")
  if not user then
    utils.log("$USER not set; live JSONL following disabled", vim.log.levels.WARN)
    return
  end

  -- Capture CWD at startup for session identification.
  M.nvim_cwd = vim.fn.getcwd()

  -- Per-pid paths avoid collisions when multiple Neovim instances run.
  local nvim_pid = vim.fn.getpid()
  M.inotify_log = string.format("/tmp/nvim.%s.%d.inotify.log", user, nvim_pid)
  M.inotify_pidfile = string.format("/tmp/nvim.%s.%d.inotify.pid", user, nvim_pid)
  M.inotify_last_pos = 0

  -- Kill watchers from dead Neovim instances using pidfiles — fast because
  -- it only reads /tmp and checks process liveness with ps, no pgrep -f scan.
  local pidfile_pattern = string.format("/tmp/nvim.%s.*.inotify.pid", user)
  local ls = io.popen("ls " .. pidfile_pattern .. " 2>/dev/null")
  if ls then
    for pidfile in ls:lines() do
      local owner_pid = pidfile:match("nvim%.[^.]+%.(%d+)%.inotify%.pid$")
      if owner_pid and owner_pid ~= tostring(nvim_pid) then
        -- Check if the owner Neovim is still alive via ps (fast, no shell expansion).
        local ps_check = io.popen("ps -p " .. owner_pid .. " -o pid= 2>/dev/null")
        local alive = ps_check and ps_check:read("*a"):match("%d") ~= nil
        if ps_check then
          ps_check:close()
        end
        if not alive then
          local pf = io.open(pidfile, "r")
          if pf then
            local watcher_pid = pf:read("*a"):match("^%s*(%d+)%s*$")
            pf:close()
            if watcher_pid then
              os.execute("kill -15 " .. watcher_pid .. " 2>/dev/null || true")
            end
          end
          os.remove(pidfile)
        end
      end
    end
    ls:close()
  end

  -- Truncate our own log (fresh start).
  local truncate = io.open(M.inotify_log, "w")
  if truncate then
    truncate:close()
  end

  utils.log("starting " .. backend .. " on " .. projects_dir, vim.log.levels.INFO)

  local handle, pid
  if backend == "inotifywait" then
    handle, pid = spawn_inotifywait(projects_dir, M.inotify_log)
  else
    handle, pid = spawn_fswatch(projects_dir, M.inotify_log)
  end

  if not handle then
    utils.log("failed to spawn " .. backend .. "; live JSONL following disabled", vim.log.levels.WARN)
    M.inotify_log = nil
    return
  end

  M.watcher_backend = backend
  M.inotify_handle = handle
  M.inotify_pid = pid

  if pid then
    local pf = io.open(M.inotify_pidfile, "w")
    if pf then
      pf:write(tostring(pid))
      pf:close()
    end
  end

  -- Poll the watcher's log file for new content.
  M.inotify_poll_timer = vim.uv.new_timer()
  M.inotify_poll_timer:start(0, 500, vim.schedule_wrap(on_inotify_poll))
end

---Stop the watcher process.
function M.stop()
  local owned = M.inotify_handle ~= nil

  -- Kill by PID directly via os.execute (not vim.uv, which may already be
  -- torn down at VimLeavePre).
  if M.inotify_pid then
    os.execute("kill -15 " .. tostring(M.inotify_pid) .. " 2>/dev/null || true")
  end

  if M.inotify_handle then
    pcall(function()
      M.inotify_handle:close()
    end)
    M.inotify_handle = nil
  end
  if M.inotify_poll_timer then
    pcall(function()
      M.inotify_poll_timer:stop()
    end)
    pcall(function()
      M.inotify_poll_timer:close()
    end)
    M.inotify_poll_timer = nil
  end
  M.inotify_pid = nil
  M.watcher_backend = nil
  -- Only clean up shared files if we owned the watcher process.
  if owned then
    if M.inotify_log then
      pcall(vim.fn.delete, M.inotify_log)
      M.inotify_log = nil
    end
    if M.inotify_pidfile then
      pcall(vim.fn.delete, M.inotify_pidfile)
      M.inotify_pidfile = nil
    end
  end
end

return M
