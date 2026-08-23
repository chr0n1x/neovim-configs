local utils = require("harness-decorators.utils")
local parser = require("harness-decorators.jsonl-parser")

---Harness adapter: per-harness paths, session identification and JSONL dialect
---parsing. The watcher is harness-agnostic - every dialect-specific decision
---goes through the adapter interface (see docs/ai/agents/adapter-structure.md).
local adapter = require("harness-decorators." .. utils.harness)
local sidecar = require("harness-decorators.sidecar")
local edit_jump = require("harness-decorators.edit-jump")

local M = {}

---Session pin state: which JSONL session belongs to this Neovim instance.
M.pinned_jsonl_path = nil

---JSONL paths confirmed to NOT belong to this Neovim's session.
M.ignored_jsonl_paths = {}

---CWD of this Neovim instance, set at startup.
M.nvim_cwd = nil

---Append a raw JSONL line to the sidecar file for the current pinned session.
local function append_sidecar(raw_line)
  local sp = sidecar.path_from_jsonl(M.pinned_jsonl_path)
  sidecar.append(sp, raw_line)
end

---Watcher state. Backend is "inotifywait" or "fswatch", whichever was found.
M.watcher_handle = nil
M.watcher_pid = nil
M.watcher_backend = nil
M.watcher_log = nil
M.watcher_last_pos = 0
M.watcher_poll_timer = nil

---Track read position per JSONL session so we can scan new lines on each event.
---Each value is { byte_pos, line_count } — byte offset and the number of lines
---scanned up to that point, so we know the absolute line number of new content.
local jsonl_positions = {}

---Pending notification handles keyed by file path, so we can update them
---when the more complete tool result arrives with a starting line.
local pending_notifications = {}

---Determine session ownership from a set of JSONL lines.
---Returns "match" (this is our session), "mismatch" (definitely not), or
---"unknown" (no evidence either way yet).
local function session_ownership(lines, jsonl_path)
  return adapter.session_ownership(M.nvim_cwd, lines, jsonl_path)
end

---Clear all per-session state and fire the reset for the given session ID.
---Call on a session-switching reset command or re-pin so the history picker
---starts fresh. jsonl_positions is intentionally NOT cleared: keeping byte
---offsets avoids a missed-write-batch immediately after re-pin.
local function reset_session_state(old_session_id)
  if old_session_id then
    edit_jump.edit_sources[old_session_id] = nil
  end
  M.pinned_jsonl_path = nil
  M.ignored_jsonl_paths = {}
  pending_notifications = {}
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
local function parse_watcher_line(raw_line)
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
  -- Subagent paths are one level deeper than the project hash dir.
  if dir:find("/subagents/") then
    return nil
  end

  -- Skip maki's pre-compaction archives (sessions/archive/<id>/N.jsonl).
  if dir:find("/archive/") then
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
  if jsonl_path:find("/archive/") then
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

  -- First encounter: check session ownership, then set the baseline at the
  -- current size. The session may have preexisting content (e.g. a resumed
  -- session), and replaying old edits would flood the buffer.
  if prev == nil then
    local ownership = session_ownership({}, jsonl_path)
    if ownership == "match" then
      utils.log("initial pin to " .. filename, vim.log.levels.DEBUG)
      try_pin_session(jsonl_path)
    elseif ownership == "mismatch" then
      utils.log("ignoring non-matching session " .. filename, vim.log.levels.DEBUG)
      M.ignored_jsonl_paths[jsonl_path] = true
    end
    -- "unknown": no evidence yet, leave as candidate and retry on the next write.
    jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }
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

  --- Session pin logic -------------------------------------------------------
  if not M.pinned_jsonl_path then
    local ownership = session_ownership(lines, jsonl_path)
    if ownership == "match" then
      utils.log("no active pin, pinning " .. filename, vim.log.levels.DEBUG)
      try_pin_session(jsonl_path)
    elseif ownership == "mismatch" then
      utils.log("ignoring non-matching session " .. filename, vim.log.levels.DEBUG)
      M.ignored_jsonl_paths[jsonl_path] = true
      return
    else
      -- "unknown": keep as candidate and retry on the next write.
      return
    end
  elseif jsonl_path ~= M.pinned_jsonl_path then
    local ownership = session_ownership(lines, jsonl_path)
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
  local cmd = adapter.find_reset_command(lines)
  if cmd then
    local old_sid = utils.extract_session_id(M.pinned_jsonl_path)
    utils.log("reset command " .. cmd .. " detected; clearing session state", vim.log.levels.INFO)
    if adapter.is_same_file_reset(cmd) then
      -- Same JSONL continues — only clear history, keep the pin.
      jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }
      utils.reset_dedup()
      if old_sid then
        edit_jump.edit_sources[old_sid] = nil
      end
      M.ignored_jsonl_paths = {}
      pending_notifications = {}
    else
      -- Session will switch to a different JSONL.
      reset_session_state(old_sid)
    end
    return
  end

  for i, line in ipairs(lines) do
    local change_info = parser.parse_tool_result(line, chunk_start_line + i - 1)
    if change_info then
      append_sidecar(line)

      -- Suppress duplicate autocmds for the same logical edit.
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
          -- The complete tool result arrived: replace the early (line-less)
          -- notification for this file, if any.
          if pending_notifications[fp] then
            utils.log(fp .. line_str, vim.log.levels.INFO, { replace = pending_notifications[fp] })
            pending_notifications[fp] = nil
          else
            utils.log(fp .. line_str)
          end
          utils.log("firing autocmd ClaudeAutoFollowEdit @ " .. fp .. line_str, vim.log.levels.DEBUG)
        else
          -- Early event (no line info yet): show a provisional notification
          -- that the tool result will replace once it lands.
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
local function process_watcher_log()
  if not M.watcher_log then
    return
  end

  local f = io.open(M.watcher_log, "r")
  if not f then
    return
  end

  local stat = f:seek("end")
  if stat == nil then
    f:close()
    return
  end
  if stat <= M.watcher_last_pos then
    f:close()
    return
  end

  -- File grew. If it grew too much, reset to avoid reading megabytes.
  if stat - M.watcher_last_pos > 65536 then
    M.watcher_last_pos = stat
    f:close()
    return
  end

  f:seek("set", M.watcher_last_pos)
  local chunk = f:read(stat - M.watcher_last_pos)
  M.watcher_last_pos = stat
  f:close()

  if not chunk then
    return
  end

  local parse_line = M.watcher_backend == "fswatch" and parse_fswatch_line or parse_watcher_line

  for line in chunk:gmatch("([^\r\n]+)") do
    local ok, jsonl_path = pcall(parse_line, line)
    if ok and jsonl_path then
      pcall(process_jsonl_write, jsonl_path)
    end
  end
end

---Callback when the watcher process exits.
local function on_watcher_exit(code)
  if M.watcher_handle then
    utils.log((M.watcher_backend or "watcher") .. " exited with code " .. tostring(code), vim.log.levels.WARN)
    M.watcher_handle = nil
  end
end

---Timer callback: process new watcher log entries.
local function on_watcher_poll()
  -- wrap in pcall so a bad log line can't kill the poll loop
  pcall(process_watcher_log)
end

---Return the resolved path of `bin` if it's on $PATH, else nil.
local function which(bin)
  local path = vim.fn.exepath(bin)
  return #path > 0 and path or nil
end

---Build the list of directories fswatch should monitor (non-recursively).
---
---Recursive fswatch (`-r`) walks and stats every node in the tree to build its
---watch list before reporting. On a large ~/.claude/projects that walk takes
---seconds, and it repeats once per Neovim instance — freezing the pane on macOS.
---We only ever act on root-session JSONLs (parse_fswatch_line skips /subagents/),
---so we watch just the directories that directly contain them:
---  * claude: the per-project hash subdirs of ~/.claude/projects
---  * maki:   the flat sessions dir itself (session JSONLs live at its top level)
---@param projects_dir string
---@return string[]
local function list_watch_dirs(projects_dir)
  if adapter.flat_sessions_dir then
    return { projects_dir }
  end

  local dirs = {}
  for path in vim.fs.dir(projects_dir, { depth = 1 }) do
    -- Skip hidden entries (leading dot on the basename). Note: claude project-hash
    -- dirs are named with a leading DASH (e.g. "-home-kran-Code"), so this must
    -- match a literal dot, not "any char after a slash".
    local base = path:match("([^/]+)$")
    if base and base:sub(1, 1) ~= "." and vim.uv.fs_stat(path) then
      dirs[#dirs + 1] = path
    end
  end

  -- Degenerate case (empty/unknown layout): fall back to the root so we never
  -- spawn fswatch with zero paths. Rare, and still far cheaper than -r.
  if #dirs == 0 then
    dirs[#dirs + 1] = projects_dir
  end
  return dirs
end

---Spawn inotifywait, writing its own output to `log_path` via --outfile.
---Watches for close_write (direct writes) and moved_to (tmp+rename pattern used
---by maki's /compact and session rewrites). Without moved_to, the watch goes
---silent after the first rename because the inode changes.
local function spawn_inotifywait(projects_dir, log_path)
  return vim.uv.spawn("inotifywait", {
    args = {
      "-m",
      "-r",
      "-e",
      "close_write,moved_to",
      "--format",
      "%w %e %f",
      projects_dir,
      "--outfile",
      log_path,
    },
  }, on_watcher_exit)
end

---Spawn fswatch, redirecting its stdout (bare path per line) to `log_path`.
---Watches each dir in `dirs` non-recursively (no -r), so fswatch never walks the
---whole tree to build its watch list. See list_watch_dirs for how dirs is built.
local function spawn_fswatch(dirs, log_path)
  local fd = vim.uv.fs_open(log_path, "w", tonumber("644", 8))
  if not fd then
    return nil
  end

  -- fswatch accepts multiple path arguments; without -r each is watched as-is.
  local args = { "-l", "0.3", "--event", "Updated" }
  for _, dir in ipairs(dirs) do
    args[#args + 1] = dir
  end

  local handle, pid = vim.uv.spawn("fswatch", {
    -- -l 0.3: coalesce writes within 300ms to avoid duplicate events.
    args = args,
    stdio = { nil, fd, nil },
  }, on_watcher_exit)

  vim.uv.fs_close(fd)
  return handle, pid
end

---Best-effort: try inotifywait, then fswatch, and give up without ever
---starting a polling fallback. Safe to call again after stop(): restarts the
---watcher (e.g. after a live config reload).
function M.start()
  if M.watcher_handle then
    return
  end
  M.stop()

  local backend = which("inotifywait") and "inotifywait" or (which("fswatch") and "fswatch")
  if not backend then
    utils.log("neither inotifywait nor fswatch found; live JSONL following disabled", vim.log.levels.WARN)
    return
  end

  -- The adapter resolves the sessions dir for its harness.
  local projects_dir = adapter.projects_dir()
  if not projects_dir then
    utils.log("no " .. utils.harness .. " sessions dir found; live JSONL following disabled", vim.log.levels.WARN)
    return
  end

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
  M.watcher_log = string.format("/tmp/nvim.%s.%d.inotify.log", user, nvim_pid)
  M.watcher_pidfile = string.format("/tmp/nvim.%s.%d.inotify.pid", user, nvim_pid)
  M.watcher_last_pos = 0

  -- Kill watchers from dead Neovim instances using pidfiles.
  -- vim.fn.glob + vim.uv.kill avoid spawning any subprocesses.
  local pidfile_pattern = string.format("/tmp/nvim.%s.*.inotify.pid", user)
  for _, pidfile in ipairs(vim.fn.glob(pidfile_pattern, false, true)) do
    local owner_pid = pidfile:match("nvim%.[^.]+%.(%d+)%.inotify%.pid$")
    if owner_pid and owner_pid ~= tostring(nvim_pid) then
      local alive = vim.uv.kill(tonumber(owner_pid), 0) ~= nil
      if not alive then
        local pf = io.open(pidfile, "r")
        if pf then
          local watcher_pid = pf:read("*a"):match("^%s*(%d+)%s*$")
          pf:close()
          if watcher_pid then
            vim.uv.kill(tonumber(watcher_pid), 15)
          end
        end
        os.remove(pidfile)
      end
    end
  end

  -- Truncate our own log (fresh start) so old entries don't leak into the new session.
  local truncate = io.open(M.watcher_log, "w")
  if truncate then
    truncate:close()
  end

  utils.log("starting " .. backend .. " on " .. projects_dir, vim.log.levels.INFO)

  local handle, pid
  if backend == "inotifywait" then
    -- inotifywait handles recursion in the kernel; spawning is cheap. Unchanged.
    handle, pid = spawn_inotifywait(projects_dir, M.watcher_log)
  else
    -- fswatch: watch only the dirs that directly hold session JSONLs, non-recursive.
    local dirs = list_watch_dirs(projects_dir)
    utils.log("fswatch watching " .. #dirs .. " dir(s)", vim.log.levels.DEBUG)
    handle, pid = spawn_fswatch(dirs, M.watcher_log)
  end

  if not handle then
    utils.log("failed to spawn " .. backend .. "; live JSONL following disabled", vim.log.levels.WARN)
    M.watcher_log = nil
    return
  end

  M.watcher_backend = backend
  M.watcher_handle = handle
  M.watcher_pid = pid

  if pid then
    local pf = io.open(M.watcher_pidfile, "w")
    if pf then
      pf:write(tostring(pid))
      pf:close()
    end
  end

  -- Poll the watcher's log file for new content.
  M.watcher_poll_timer = vim.uv.new_timer()
  M.watcher_poll_timer:start(0, 500, vim.schedule_wrap(on_watcher_poll))

  utils.log("watcher started on " .. projects_dir, vim.log.levels.INFO)
end

---Stop the watcher process.
function M.stop()
  local owned = M.watcher_handle ~= nil

  -- Kill by PID directly via os.execute (not vim.uv, which may already be
  -- torn down at VimLeavePre).
  if M.watcher_pid then
    os.execute("kill -15 " .. tostring(M.watcher_pid) .. " 2>/dev/null || true")
  end

  if M.watcher_handle then
    pcall(function()
      M.watcher_handle:close()
    end)
    M.watcher_handle = nil
  end
  if M.watcher_poll_timer then
    pcall(function()
      M.watcher_poll_timer:stop()
    end)
    pcall(function()
      M.watcher_poll_timer:close()
    end)
    M.watcher_poll_timer = nil
  end
  M.watcher_pid = nil
  M.watcher_backend = nil
  -- Only clean up shared files if we owned the watcher process.
  if owned then
    if M.watcher_log then
      pcall(vim.fn.delete, M.watcher_log)
      M.watcher_log = nil
    end
    if M.watcher_pidfile then
      pcall(vim.fn.delete, M.watcher_pidfile)
      M.watcher_pidfile = nil
    end
  end
end

return M
