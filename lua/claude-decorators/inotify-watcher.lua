local utils = require("claude-decorators.utils")
local parser = require("claude-decorators.jsonl-parser")

local M = {}

---Session pin state: which JSONL session matches the visible terminal.
M.pinned_jsonl_path = nil

---Inotify watcher state.
M.inotify_handle = nil
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

---Legacy fallback stubs (used when inotifywait is unavailable).
local poll_timer = nil

local function start_watch()
  if poll_timer then return end
  utils.log("polling fallback activated (inotifywait unavailable)", vim.log.levels.WARN)
end

function M.stop_legacy_poll()
  if poll_timer then
    pcall(function() poll_timer:stop() end)
    pcall(function() poll_timer:close() end)
    poll_timer = nil
  end
end

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
  if jsonl_path == M.pinned_jsonl_path then
    -- Process (fall through below).
  elseif not M.pinned_jsonl_path then
    utils.log("no active pin, trying to pin " .. filename, vim.log.levels.DEBUG)
    if not try_pin_session(jsonl_path) then return end
  else
    utils.log("session switch detected, re-pin to " .. filename, vim.log.levels.DEBUG)
    M.pinned_jsonl_path = nil
    if not try_pin_session(jsonl_path) then return end
  end

  --- Tool result processing -----------------------------------------------
  -- Scan all new content appended to the JSONL since we last checked this file.
  -- This catches tool results even when non-tool entries (system summaries, etc.)
  -- are appended after the tool result line.
  local f = io.open(jsonl_path, "r")
  if not f then return end
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

    if not chunk then return end

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
          -- Dedup check.
          local dedup_key = change_info.dedup_key
          if dedup_key and utils.key_seen(dedup_key) then
            utils.log("NOT firing autocmd; SEEN " .. dedup_key:sub(1, 8), vim.log.levels.DEBUG)
          else
            if dedup_key then utils.mark_key_seen(dedup_key) end

            local fp = change_info.file_path
            local line_str = change_info.starting_line and ":" .. change_info.starting_line or ""

            if change_info.starting_line then
              -- Complete result: update or show notification with line number.
              if pending_notifications[fp] then
                utils.log(
                  fp .. line_str,
                  vim.log.levels.INFO,
                  { replace = pending_notifications[fp] }
                )
                pending_notifications[fp] = nil
              else
                utils.log(fp .. line_str)
              end
              utils.log(
                "firing autocmd ClaudeAutoFollowEdit @ " .. fp .. line_str,
                vim.log.levels.DEBUG
              )
            else
              -- Early tool_use (no line info): show notification that can be
              -- updated when the toolUseResult arrives.
              local handle = utils.log(fp, vim.log.levels.INFO)
              pending_notifications[fp] = handle
              utils.log(
                "early tool_use @ " .. fp,
                vim.log.levels.DEBUG
              )
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
              },
            })
          end
        end
      end
    end
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

  for line in chunk:gmatch("([^\r\n]+)") do
    pcall(on_inotify_event, line)
  end
end

---Callback when inotifywait process exits.
local function on_inotify_exit(code)
  if M.inotify_handle then
    utils.log(
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

---Ensure a single global inotifywait watcher is running.
---Uses a lockfile with the inotifywait PID to prevent duplicates.
function M.start()
  if M.inotify_handle then return end

  -- Check if inotifywait is available.
  local check = io.popen("which inotifywait 2>/dev/null")
  if check then
    local path = check:read("*a"):gsub("%s+", "")
    check:close()
    if #path == 0 then
      utils.log("inotifywait not found, falling back to polling", vim.log.levels.WARN)
      start_watch()
      return
    end
  else
    utils.log("inotifywait not found, falling back to polling", vim.log.levels.WARN)
    start_watch()
    return
  end

  local projects_dir = os.getenv("HOME") .. "/.claude/projects"

  -- Check if directory exists.
  local f = io.open(projects_dir, "r")
  if not f then
    utils.log("projects dir does not exist: " .. projects_dir, vim.log.levels.WARN)
    start_watch()
    return
  end
  f:close()

  -- Create a temp file for inotifywait to append to.
  local user = os.getenv("USER") or "kran"
  M.inotify_log = string.format("/tmp/nvim.%s.inotify.log", user)
  M.inotify_pidfile = string.format("/tmp/nvim.%s.inotify.pid", user)
  M.inotify_last_pos = 0

  -- Kill any orphaned watchers from previous Neovim sessions.
  -- Always pgrep to catch orphans even when the pidfile is stale/corrupt.
  local kp = io.popen(
    "pgrep -f 'inotifywait.*nvim." .. user .. ".inotify' 2>/dev/null || true"
  )
  if kp then
    for pid_line in kp:lines() do
      local p = tonumber(pid_line:match("^%s*(.-)%s*$"))
      if p then
        pcall(function() vim.uv.kill(p, 15) end)
      end
    end
    kp:close()
  end

  -- Truncate any leftover log.
  local truncate = io.open(M.inotify_log, "w")
  if truncate then truncate:close() end

  -- Spawn inotifywait directly (no bash wrapper) and capture its PID.
  local cmd = "inotifywait"
  local args = {
    "-m", "-r", "-e", "close_write",
    "--format", "%w %e %f",
    projects_dir,
    "--outfile", M.inotify_log,
  }

  utils.log("starting inotifywait on " .. projects_dir, vim.log.levels.INFO)

  M.inotify_handle = vim.uv.spawn(cmd, { args = args }, on_inotify_exit)

  if not M.inotify_handle then
    utils.log("failed to spawn inotifywait, falling back to polling", vim.log.levels.WARN)
    M.inotify_log = nil
    start_watch()
    return
  end

  -- Write the actual PID of the spawned inotifywait process.
  -- vim.uv.spawn returns a handle, not the PID — discover it via pgrep
  -- matching our unique log file path (safer than relying on handle internals).
  vim.defer_fn(function()
    local my_pid = io.popen(
      "pgrep -f 'inotifywait.*" .. vim.fn.fnameescape(M.inotify_log) .. "' 2>/dev/null || true"
    )
    if my_pid then
      local pid_line = my_pid:read("*l")
      my_pid:close()
      if pid_line then
        local pf = io.open(M.inotify_pidfile, "w")
        if pf then
          pf:write(pid_line:match("^%s*(.-)%s*$"))
          pf:close()
        end
      end
    end
  end, 200)

  -- Poll the inotify log file for new content.
  M.inotify_poll_timer = vim.uv.new_timer()
  M.inotify_poll_timer:start(0, 500, vim.schedule_wrap(on_inotify_poll))
end

---Stop the inotifywait watcher process.
function M.stop()
  local owned = M.inotify_handle ~= nil

  -- Kill via pgrep as a reliable fallback when vim.uv may be torn down (VimLeavePre).
  local user = os.getenv("USER")
  if not user then
    utils.log("NO $USER UNABLE TO INITIATE inotifywait STOP", vim.log.levels.ERROR)
    return
  end
  pcall(function()
    local kp = io.popen(
      "pgrep -f 'inotifywait.*nvim." .. user .. ".inotify' 2>/dev/null || true"
    )
    if kp then
      for pid_line in kp:lines() do
        local p = tonumber(pid_line:match("^%s*(.-)%s*$"))
        if p then
          -- Try vim.uv first, fall back to os.kill.
          local ok, _ = pcall(function() vim.uv.kill(p, 15) end)
          if not ok then
            os.execute("kill -15 " .. tostring(p) .. " 2>/dev/null || true")
          end
        end
      end
      kp:close()
    end
  end)

  if M.inotify_handle then
    pcall(function() M.inotify_handle:close() end)
    M.inotify_handle = nil
  end
  if M.inotify_poll_timer then
    pcall(function() M.inotify_poll_timer:stop() end)
    pcall(function() M.inotify_poll_timer:close() end)
    M.inotify_poll_timer = nil
  end
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
