local utils = require("claude-decorators.utils")
local parser = require("claude-decorators.jsonl-parser")
local sidecar = require("claude-decorators.sidecar")

local M = {}

---Session pin state: which JSONL session matches the visible terminal.
M.pinned_jsonl_path = nil

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

---Pin to a JSONL session. Whichever JSONL is receiving writes is the active session.
local function try_pin_session(jsonl_path)
  if M.pinned_jsonl_path == jsonl_path then
    return true
  end
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

---Handle a confirmed JSONL write: pin the session and scan new lines.
local function process_jsonl_write(jsonl_path)
  local filename = jsonl_path:match("[^/]+$")

  --- Session pin logic ---------------------------------------------------
  if not M.pinned_jsonl_path then
    utils.log("no active pin, trying to pin " .. filename, vim.log.levels.DEBUG)
    if not try_pin_session(jsonl_path) then
      return
    end
  elseif jsonl_path ~= M.pinned_jsonl_path then
    utils.log("session switch detected, re-pin to " .. filename, vim.log.levels.DEBUG)
    M.pinned_jsonl_path = nil
    if not try_pin_session(jsonl_path) then
      return
    end
  end

  --- Tool result processing -----------------------------------------------
  -- Scan all new content appended to the JSONL since we last checked this file.
  -- This catches tool results even when non-tool entries (system summaries, etc.)
  -- are appended after the tool result line.
  -- We read a byte-range chunk rather than tailing by line count because
  -- each watcher event fires per-write, and each write is one JSONL line.
  local f = io.open(jsonl_path, "r")
  if not f then
    return
  end
  local file_size = f:seek("end")
  f:close()

  local prev_pos = jsonl_positions[jsonl_path] and jsonl_positions[jsonl_path].byte_pos

  -- First time seeing this file: mark current size as the baseline.
  -- Don't scan old content — only react to new writes after startup.
  if prev_pos == nil then
    jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }
    return
  end

  if file_size <= prev_pos then
    return
  end

  local chunk_file = io.open(jsonl_path, "r")
  if chunk_file then
    chunk_file:seek("set", prev_pos)
    local chunk = chunk_file:read(file_size - prev_pos)
    chunk_file:close()

    if not chunk then
      return
    end

    local lines = {}
    for line in chunk:gmatch("([^\r\n]+)") do
      lines[#lines + 1] = line
    end

    -- The line count tracked at the previous byte position tells us where
    -- the first line in this chunk starts (1-indexed).
    local prev_line_count = jsonl_positions[jsonl_path].line_count or 0
    local chunk_start_line = prev_line_count + 1

    -- Update tracked position after reading, before processing.
    local new_line_count = prev_line_count + #lines
    jsonl_positions[jsonl_path] = {
      byte_pos = file_size,
      line_count = new_line_count,
    }

    for i, line in ipairs(lines) do
      local change_info = parser.parse_tool_result(line, chunk_start_line + i - 1)
      if change_info then
        -- Write raw line to sidecar before dedup — we want all events recorded.
        append_sidecar(line)

        -- Dedup check: prevent firing duplicate autocmds when both the early
        -- tool_use and the later toolUseResult arrive for the same edit.
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
            -- Complete result: update or show notification with line number.
            if pending_notifications[fp] then
              utils.log(fp .. line_str, vim.log.levels.INFO, { replace = pending_notifications[fp] })
              pending_notifications[fp] = nil
            else
              utils.log(fp .. line_str)
            end
            utils.log("firing autocmd ClaudeAutoFollowEdit @ " .. fp .. line_str, vim.log.levels.DEBUG)
          else
            -- Early tool_use (no line info): show notification that can be
            -- updated when the toolUseResult arrives.
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
  M.inotify_log = string.format("/tmp/nvim.%s.inotify.log", user)
  M.inotify_pidfile = string.format("/tmp/nvim.%s.inotify.pid", user)
  M.inotify_last_pos = 0

  -- Kill any orphaned watchers (either backend) from previous Neovim
  -- sessions, identified by them watching our projects dir.
  local kp =
    io.popen("pgrep -f '(inotifywait|fswatch).*" .. vim.fn.fnameescape(projects_dir) .. "' 2>/dev/null || true")
  if kp then
    for pid_line in kp:lines() do
      local p = tonumber(pid_line:match("^%s*(.-)%s*$"))
      if p then
        os.execute("kill -15 " .. tostring(p) .. " 2>/dev/null || true")
      end
    end
    kp:close()
  end

  -- Truncate any leftover log.
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
