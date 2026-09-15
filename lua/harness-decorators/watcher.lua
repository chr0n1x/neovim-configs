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

---True after the first visible pin notification for the current session.
---Reset on session switch so a new session gets its own notification.
M.pin_notified = false

---JSONL paths confirmed to NOT belong to this Neovim's session.
M.ignored_jsonl_paths = {}

---CWD of this Neovim instance, set at startup.
M.nvim_cwd = nil

---Append a raw JSONL line to the sidecar file for the current pinned session.
local function append_sidecar(raw_line)
  local sp = sidecar.path_from_jsonl(M.pinned_jsonl_path)
  sidecar.append(sp, raw_line)
end

---Dispatch a single parsed change: append it to the sidecar, gate on the dedup key, and -
---when not already seen - mark it seen and fire the User HarnessEdit autocmd with the
---9-field data table consumed by edit-jump.lua and the history picker. This is the one
---place that builds that data table, so its shape changes in exactly one spot.
---@param change_info table The result of parser.parse_tool_result (non-nil).
---@param line string The raw JSONL line, appended to the sidecar.
---@param before_fire? fun(change_info: table) Optional hook run after the dedup key is
---  marked seen but before the autocmd fires - process_jsonl_write uses it for its
---  early/complete tool-result notification logic.
---@return boolean fired True if the autocmd was fired (i.e. not a duplicate), false if
---  suppressed by the dedup key. Callers use this to decide whether to log a suppression.
local function dispatch_change(change_info, line, before_fire)
  append_sidecar(line)
  local dedup_key = change_info.dedup_key
  if dedup_key and utils.key_seen(dedup_key) then
    return false
  end
  if dedup_key then
    utils.mark_key_seen(dedup_key)
  end
  if before_fire then
    before_fire(change_info)
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "HarnessEdit",
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
  return true
end

---Watcher state. Backend is "inotifywait" or "fswatch", whichever was found.
M.watcher_handle = nil
M.watcher_pid = nil
M.watcher_backend = nil
M.watcher_log = nil
M.watcher_last_pos = 0
M.watcher_poll_timer = nil

---How often the poll loop sweeps orphaned watchers from crashed nvims (ms), and
---the monotonic timestamp of the last sweep.
M.reap_interval_ms = 30000
M._last_reap_ms = nil

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

---Extract the session id a set of JSONL lines declare for themselves (Option B pin key).
---Delegates to the adapter's session_id_from_lines; returns nil when the dialect carries no
---in-line id (copilot) so the caller falls back to path-based inference.
---@param lines string[]
---@return string?
local function declared_session_id(lines)
  if adapter.session_id_from_lines then
    local ok, id = pcall(adapter.session_id_from_lines, lines)
    if ok and type(id) == "string" and #id > 0 then
      return id
    end
  end
  return nil
end

---The full set of per-session state fields, each with its "cleared" value. This is the single
--definition of what "all session state" means. jsonl_positions and pending_notifications are
--module-local (not on M) but are part of session state. `reset(opts)` below clears a named subset;
--every reset site picks the flags it needs, so a field added here is easy to audit for coverage.
---
---Flag semantics:
---  pin                pinned_jsonl_path / pinned_session_id / ignored_jsonl_paths / pin_notified
---  pending            pending_notifications (early tool-result notification handles)
---  positions          jsonl_positions (byte offsets; keep on re-pin to avoid a missed-write-batch)
---  edit_sources       edit_jump.edit_sources for every session (harness switch only - a mid-work
---                     /resume must NOT wipe prior diffs from <leader>cu)
---  dedup              utils dedup cache
local function reset(opts)
  if opts.pin then
    M.pinned_jsonl_path = nil
    M.pinned_session_id = nil
    M.ignored_jsonl_paths = {}
    M.pin_notified = false
  end
  if opts.pending then
    pending_notifications = {}
  end
  if opts.positions then
    jsonl_positions = {}
  end
  if opts.edit_sources then
    edit_jump.edit_sources = {}
  end
  if opts.dedup then
    utils.reset_dedup()
  end
end

---Clear the pin-state trio shared by every reset site: which session is pinned (by both path
---and declared id), which paths are confirmed foreign, and whether the pin notification has
---fired. The other fields in the full set (jsonl_positions, pending_notifications) are NOT part of
---this - they are only cleared where a full re-scan is wanted (see M.reset_all). Exposed so
---init.setup_auto_follow can reset the same trio without reaching into watcher's internals.
function M.reset_pin_state()
  reset({ pin = true })
end

---Clear per-session RUNTIME state on a session switch (re-pin or a reset command detected in
---the pinned session). Unlike M.reset_all this does NOT clear jsonl_positions: keeping byte offsets
---avoids a missed-write-batch immediately after re-pin.
---
---It deliberately does NOT delete the old session's edit history (edit_sources[old_id]). A mid-work
---switch (/resume to a new JSONL) should not make prior diffs disappear from <leader>cu - the user
---explicitly chose "preserve old history" over wiping it. The picker shows only the CURRENTLY pinned
---session's records, so preserved history stays reachable by re-pinning the old session and never
---pollutes the current view. (M.reset_all still wipes all history on a harness switch, where nothing
---from the previous harness should leak.)
local function reset_session_state(_old_session_id)
  reset({ pin = true, pending = true })
end

---Clear ALL per-session state: every field in the set above, plus the edit-jump history for every
---session and the utils dedup cache. Used by set_harness, where nothing from the previous harness may
---leak into the new one. (reset_log is NOT part of this: the logger's cooldown cache is keyed by
---message text and is not per-session state; init.setup_auto_follow clears it separately at startup.)
function M.reset_all()
  reset({ pin = true, pending = true, positions = true, edit_sources = true, dedup = true })
end

---Pin to a JSONL session, recording both its path and its declared session id (Option B). The
---declared id - extracted from the JSONL's own header via adapter.session_id_from_lines, with a
---path-based fallback for dialects that carry no in-line id (copilot) - is what the pin locks
---on. Cwd was only ever the initial candidate filter; once a session declares an id we key on
---that id so a stale same-cwd session cannot hijack the pin.
---@param jsonl_path string The JSONL to pin to.
---@param declared_id string? The session id declared in the JSONL lines, if any.
local function try_pin_session(jsonl_path, declared_id)
  -- Same path AND same (or no new) id: nothing to do. But the SAME path declaring a NEW id is
  -- a genuine mid-work switch (/resume continuing in one JSONL) and must still re-pin below.
  local new_name = declared_id or utils.extract_session_id(jsonl_path) or jsonl_path:match("[^/]+$")
  if M.pinned_jsonl_path == jsonl_path and (not declared_id or M.pinned_session_id == declared_id) then
    return true
  end
  local old_session_id = M.pinned_session_id or utils.extract_session_id(M.pinned_jsonl_path)
  if old_session_id then
    utils.log("re-pin: moving off session " .. old_session_id:sub(1, 8), vim.log.levels.DEBUG)
  end
  reset_session_state(old_session_id)

  M.pinned_jsonl_path = jsonl_path
  -- Prefer the declared id; fall back to path inference for dialects without an in-line id.
  M.pinned_session_id = new_name
  if not M.pin_notified then
    utils.log("session detected " .. new_name, vim.log.levels.INFO)
    M.pin_notified = true
  else
    utils.log("session detected " .. new_name, vim.log.levels.DEBUG)
  end
  return true
end

---Shared path filters for both watcher backends. Returns the jsonl path if it should be
---processed, or nil if it must be ignored. Only root-session .jsonl files count: subagent
---paths (one level deeper than the project hash dir) and maki's pre-compaction archives
---(sessions/archive/<id>/N.jsonl) are skipped.
---@param path string A full jsonl candidate path.
---@return string|nil The path if it passes the filters, else nil.
local function filter_jsonl_path(path)
  if not path:match("%.jsonl$") then
    return nil
  end
  if path:find("/subagents/") then
    return nil
  end
  if path:find("/archive/") then
    return nil
  end
  return path
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

  -- Strip trailing slash from dir, then apply the shared path filters.
  dir = dir:gsub("/+$", "")
  return filter_jsonl_path(dir .. "/" .. filename)
end

---Parse an fswatch log line: a bare absolute path, one per line (fswatch's
---default output format when no --format/-x flags are given).
---Returns the full jsonl path, or nil if the line should be ignored.
local function parse_fswatch_line(raw_line)
  if not raw_line or #raw_line == 0 then
    return nil
  end

  local jsonl_path = raw_line:match("^%s*(.-)%s*$")
  return filter_jsonl_path(jsonl_path)
end

---Process a set of recovered JSONL lines (e.g. from a pin-time tail scan) through
---the same parse + autocmd path as live writes, so they land in edit_sources and
---the sidecar. Exposed to adapters via M.process_recovered_lines so the harness
---owns *what* to recover while the watcher owns *how* an event is dispatched.
---@param lines string[] The JSONL lines to process
---@param line_offset number? Offset added to each 1-based index to derive source_line.
---                           Adapters scanning a tail pass a negative base since they
---                           don't know the absolute line numbers.
function M.process_recovered_lines(lines, line_offset)
  for i, line in ipairs(lines) do
    local change_info = parser.parse_tool_result(line, (line_offset or 0) + i)
    if change_info then
      dispatch_change(change_info, line)
    end
  end
end

---Handle a confirmed JSONL write: identify session ownership, then scan new lines. Exposed as
---M.process_jsonl_write so tests/ownership_spec.lua can drive the real pin path (pin-by-session-
---id, switch-on-declared-id, preserve-history) without spawning an inotifywait backend.
function M.process_jsonl_write(jsonl_path)
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

  -- First encounter: check session ownership. On a match, pin. By default the
  -- baseline is set at the current file size so preexisting content is never
  -- replayed. An adapter may opt into recovering in-flight edits via on_pin()
  -- (maki does, because it writes its JSONL in atomic write+rename bursts): it
  -- returns a new baseline byte offset after scanning whatever it chose to
  -- recover. Nil/absent hook = no recovery, baseline stays at file_size.
  if prev == nil then
    -- Already pinned: record position for this new file but never re-pin.
    -- The pin is locked until a reset command is detected in the pinned session.
    if M.pinned_jsonl_path then
      utils.log("pin locked; ignoring new session " .. filename, vim.log.levels.DEBUG)
      jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }
      return
    end

    local ownership = session_ownership({}, jsonl_path)
    if ownership == "match" then
      utils.log("initial pin to " .. filename, vim.log.levels.DEBUG)
      -- Pin on the id the file declares (Option B); cwd was only the initial filter. The
      -- first-encounter path has no parsed lines yet, so fall back to path inference here -
      -- the incremental path below upgrades to the declared id once lines arrive.
      try_pin_session(jsonl_path, declared_session_id({}))

      local base = file_size
      if adapter.on_pin then
        local ok, result = pcall(adapter.on_pin, jsonl_path, file_size)
        if ok and type(result) == "number" and result >= 0 then
          base = result
        end
      end

      jsonl_positions[jsonl_path] = { byte_pos = base, line_count = 0 }
    elseif ownership == "mismatch" then
      utils.log("ignoring non-matching session " .. filename, vim.log.levels.DEBUG)
      M.ignored_jsonl_paths[jsonl_path] = true
      jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }
    else
      -- "unknown": no cwd evidence yet. Record the position so the NEXT write takes the
      -- incremental path and can read real lines to decide ownership + pin. Without this the
      -- file would re-enter first-encounter forever (empty lines => always unknown).
      jsonl_positions[jsonl_path] = { byte_pos = file_size, line_count = 0 }
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

  --- Session pin logic (Option B: key on the declared session id, not cwd) ----------
  local this_id = declared_session_id(lines)

  if not M.pinned_jsonl_path then
    -- No pin yet. Cwd is only the initial candidate filter; once this file declares a session
    -- id we lock onto THAT id, so a stale same-cwd session cannot win the pin first. We require
    -- BOTH a cwd match AND a declared id: a cwd-matching file with no id yet stays a candidate
    -- (retry next write) rather than claiming the pin on cwd alone.
    local ownership = session_ownership(lines, jsonl_path)
    if ownership == "match" and this_id then
      utils.log("no active pin, pinning " .. filename, vim.log.levels.DEBUG)
      try_pin_session(jsonl_path, this_id)
    elseif ownership == "mismatch" then
      utils.log("ignoring non-matching session " .. filename, vim.log.levels.DEBUG)
      M.ignored_jsonl_paths[jsonl_path] = true
      return
    else
      -- "unknown", or a cwd match with no declared id yet: keep as candidate, retry next write.
      return
    end
  elseif this_id and M.pinned_session_id and this_id ~= M.pinned_session_id then
    if jsonl_path == M.pinned_jsonl_path then
      -- The PINNED file itself now declares a different id: a genuine mid-work switch
      -- (/resume, /new continuing in the same JSONL). Re-pin to it. The old session's history
      -- is preserved (see reset_session_state), not wiped.
      local msg = "session switched " .. M.pinned_session_id:sub(1, 8) .. " -> " .. this_id:sub(1, 8)
      utils.log(msg, vim.log.levels.INFO)
      try_pin_session(jsonl_path, this_id)
    else
      -- A DIFFERENT file declares a different id: a stale/foreign same-cwd session. The pin is
      -- locked to its session; ignore it (a reset command in the pinned session re-opens the switch).
      utils.log("ignoring foreign session " .. this_id:sub(1, 8) .. " from " .. filename, vim.log.levels.DEBUG)
    end
    return
  elseif jsonl_path ~= M.pinned_jsonl_path then
    -- Same (or no) declared id but a different file: the pin is locked to its session; ignore
    -- writes from any other path until a reset command re-opens the switch.
    return
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
      -- Suppress duplicate autocmds for the same logical edit. The notification logic
      -- (early vs complete tool result) runs as a before_fire hook so it fires only when
      -- the autocmd actually fires, and in the same order as before.
      local dedup_key = change_info.dedup_key
      local fired = dispatch_change(change_info, line, function(ci)
        local fp = ci.file_path
        local line_str = ci.starting_line and ":" .. ci.starting_line or ""

        if ci.starting_line then
          -- The complete tool result arrived: replace the early (line-less)
          -- notification for this file, if any.
          if pending_notifications[fp] then
            utils.log(fp .. line_str, vim.log.levels.INFO, { replace = pending_notifications[fp] })
            pending_notifications[fp] = nil
          else
            utils.log(fp .. line_str)
          end
          utils.log("firing autocmd HarnessEdit @ " .. fp .. line_str, vim.log.levels.DEBUG)
        else
          -- Early event (no line info yet): show a provisional notification
          -- that the tool result will replace once it lands.
          local handle = utils.log(fp, vim.log.levels.INFO)
          pending_notifications[fp] = handle
          utils.log("early tool_use @ " .. fp, vim.log.levels.DEBUG)
        end
      end)
      if not fired and dedup_key then
        utils.log("NOT firing autocmd; SEEN " .. dedup_key:sub(1, 8), vim.log.levels.DEBUG)
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
      pcall(M.process_jsonl_write, jsonl_path)
    end
  end
end

---Callback when the watcher process exits. Owns all cleanup so nothing is
---discarded while the process is still dying: closing the handle here (not in
---stop()) lets libuv reap the child, which is what prevents a zombie from
---lingering under a live nvim after stop().
local function on_watcher_exit(code)
  if M.watcher_handle then
    local level = (code == 0) and vim.log.levels.DEBUG or vim.log.levels.WARN
    utils.log((M.watcher_backend or "watcher") .. " exited with code " .. tostring(code), level)
    pcall(function()
      M.watcher_handle:close()
    end)
    M.watcher_handle = nil
  end

  -- Only clean up shared files if this exit belongs to the current watcher;
  -- a late callback from an already-replaced watcher must not delete the new
  -- one's files. stop() is responsible for clearing these on shutdown paths
  -- where the callback may never fire (uv torn down at VimLeavePre).
  if M.watcher_log then
    pcall(vim.fn.delete, M.watcher_log)
    M.watcher_log = nil
  end
  if M.watcher_pidfile then
    pcall(vim.fn.delete, M.watcher_pidfile)
    M.watcher_pidfile = nil
  end
end

---Reap watcher processes left behind by dead Neovim instances.
---
---Each nvim writes /tmp/nvim.$USER.<nvim_pid>.inotify.pid containing its
---watcher's pid. When an nvim exits cleanly, VimLeavePre -> stop() kills its
---watcher and removes the pidfile. But a crash or `kill -9` skips VimLeavePre,
---so the watcher (fswatch/inotifywait) is reparented to init/launchd and keeps
---running forever - an orphan. This walks every pidfile, and for any whose
---OWNER nvim is dead, kills the recorded watcher pid and removes the pidfile.
---
---Safe to run from any live instance: the owner-alive check (signal 0) means we
---never touch a running nvim's watcher, and we always skip our own pidfile.
---Concurrent sweeps from multiple instances race harmlessly (SIGTERM to an
---already-dead pid and os.remove of an already-gone file are both no-ops).
---@param self_pid number This nvim's pid, never reaped.
local function reap_dead_watchers(self_pid)
  local user = os.getenv("USER")
  if not user then
    return
  end
  local pidfile_pattern = string.format("/tmp/nvim.%s.*.inotify.pid", user)
  for _, pidfile in ipairs(vim.fn.glob(pidfile_pattern, false, true)) do
    local owner_pid = pidfile:match("nvim%.[^.]+%.(%d+)%.inotify%.pid$")
    if owner_pid and owner_pid ~= tostring(self_pid) then
      -- signal 0 probes liveness without delivering a signal: non-nil => alive.
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
end

---Timer callback: process new watcher log entries.
local function on_watcher_poll()
  -- wrap in pcall so a bad log line can't kill the poll loop
  pcall(process_watcher_log)

  -- Periodically sweep orphaned watchers from crashed nvims. Reaping at start()
  -- alone is lazy - orphans from a crash linger until the NEXT nvim launch. Any
  -- live instance running this loop cleans them within one sweep interval, so
  -- orphans self-heal without waiting for a fresh nvim. Throttled well below the
  -- 500ms poll cadence to keep it cheap.
  local now = math.floor(vim.uv.hrtime() / 1000000)
  if not M._last_reap_ms or (now - M._last_reap_ms) >= M.reap_interval_ms then
    M._last_reap_ms = now
    pcall(reap_dead_watchers, vim.fn.getpid())
  end
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
---
---macOS avoids this entirely: fswatch's FSEvents backend reports the whole
---SUBTREE of any watched path even without -r, so we watch just the root. That
---keeps the command short, skips the startup tree-walk, and — unlike enumerating
---subdirs at spawn time — automatically catches session dirs created AFTER nvim
---started (e.g. the first Claude session in a brand-new repo).
---
---Non-macOS fswatch (a rare fallback; Linux prefers inotifywait) uses the inotify
---backend, which is NOT subtree-recursive. There we watch the root but must let
---the caller add -r for non-flat layouts (JSONLs one dir deep). Flat layouts keep
---their JSONLs at the root, so no recursion is needed on any platform.
---@param projects_dir string
---@return string[] dirs, boolean recursive
local function resolve_watch(projects_dir)
  local is_macos = vim.uv.os_uname().sysname == "Darwin"
  -- Root-only is sufficient when either the backend reports the subtree (macOS
  -- FSEvents) or the JSONLs already sit at the root (flat harness). Otherwise the
  -- caller needs -r so nested per-project JSONLs are seen.
  local recursive = not is_macos and not adapter.flat_sessions_dir
  return { projects_dir }, recursive
end

---The inotify event set. close_write+moved_to cover direct writes and the tmp+rename pattern;
--flat-session harnesses (maki, copilot) keep their JSONL open and append, so they additionally
--need modify - which is exactly the flat_sessions_dir adapters already expose for resolve_watch.
---Extra events are harmless: the byte-offset dedup in process_jsonl_write makes a redundant poll
---a cheap no-op. Adapters may still override via inotify_events() if their needs diverge.
local function inotify_event_set()
  local base = "close_write,moved_to"
  if adapter.flat_sessions_dir then
    base = base .. ",modify"
  end
  if type(adapter.inotify_events) == "function" then
    local ev = adapter.inotify_events()
    if type(ev) == "string" and #ev > 0 then
      return ev
    end
  end
  return base
end

---Spawn inotifywait, writing its own output to `log_path` via --outfile.
local function spawn_inotifywait(projects_dir, log_path)
  local events = inotify_event_set()
  return vim.uv.spawn("inotifywait", {
    args = {
      "-m",
      "-r",
      "-e",
      events,
      "--format",
      "%w %e %f",
      projects_dir,
      "--outfile",
      log_path,
    },
  }, on_watcher_exit)
end

---Spawn fswatch, redirecting its stdout (bare path per line) to `log_path`.
---Watches `dirs`; passes -r only when `recursive` is set (non-macOS non-flat).
---On macOS the FSEvents backend already reports the subtree, so -r is omitted to
---avoid the expensive whole-tree watch-list build. See resolve_watch.
local function spawn_fswatch(dirs, log_path, recursive)
  local fd = vim.uv.fs_open(log_path, "w", tonumber("644", 8))
  if not fd then
    return nil
  end

  local args = { "-l", "0.3", "--event", "Updated" }
  if recursive then
    args[#args + 1] = "-r"
  end
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

  -- Kill watchers from dead Neovim instances using pidfiles. Also runs
  -- periodically from the poll loop so crash-orphans don't wait for a new start.
  reap_dead_watchers(nvim_pid)

  -- Truncate our own log (fresh start) so old entries don't leak into the new session.
  local truncate = io.open(M.watcher_log, "w")
  if truncate then
    truncate:close()
  end

  utils.log("starting " .. backend .. " on " .. projects_dir, vim.log.levels.DEBUG)

  local handle, pid
  if backend == "inotifywait" then
    -- inotifywait handles recursion in the kernel; spawning is cheap. Unchanged.
    handle, pid = spawn_inotifywait(projects_dir, M.watcher_log)
  else
    -- fswatch: watch the root; recursion depends on backend/layout (resolve_watch).
    local dirs, recursive = resolve_watch(projects_dir)
    utils.log("fswatch watching " .. #dirs .. " dir(s)" .. (recursive and " (-r)" or ""), vim.log.levels.DEBUG)
    handle, pid = spawn_fswatch(dirs, M.watcher_log, recursive)
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

  utils.log("watcher started on " .. projects_dir, vim.log.levels.DEBUG)
end

---Re-point the watcher at a different harness at runtime (called by switch.lua
---when the user swaps the backing CLI without restarting Neovim).
---
---The adapter and notify prefix are otherwise bound once at module load, so a
---plain harness swap would leave this watcher following the OLD harness's
---sessions dir, still pinned to the old session, and still firing HarnessEdit -
---which is what let edit-jump wander into files edited by another harness.
---
---This reloads the adapter, updates utils.harness, and wipes ALL per-session
---state so nothing from the previous harness can leak into the new one. The
---caller is responsible for stop()/start() around it.
---@param name string the new harness name (must match a sibling adapter dir)
function M.set_harness(name)
  utils.harness = name
  package.loaded["harness-decorators." .. name] = nil
  adapter = require("harness-decorators." .. name)

  -- Wipe ALL per-session state (pin, ownership, scan offsets, pending notifications,
  -- every session's edit history, and the dedup cache) so nothing from the previous harness
  -- can leak into the new one. See M.reset_all for the single definition of that set.
  M.reset_all()
end

---Stop the watcher process.
function M.stop()
  local owned = M.watcher_handle ~= nil

  -- Kill by PID directly via os.execute (not vim.uv, which may already be
  -- torn down at VimLeavePre).
  if M.watcher_pid then
    os.execute("kill -15 " .. tostring(M.watcher_pid) .. " 2>/dev/null || true")
  end

  -- Do NOT delete the log file here: inotifywait holds its --outfile fd open
  -- and would keep writing into a dangling inode until it finally dies. The
  -- exit callback (or start()'s truncate) handles cleanup once the process is
  -- actually gone. Same for the handle - closing it before the child exits
  -- races libuv's reaper and leaves a zombie under a live nvim.

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

  if owned then
    -- Wait for the exit callback to finish cleanup. Bounded so a watcher that
    -- ignores SIGTERM can't hang us; on timeout the files are removed here as
    -- a fallback (the process is dead or dying either way).
    local deadline = vim.uv.hrtime() + 2 * 1000000000 -- 2s
    while M.watcher_handle and vim.uv.hrtime() < deadline do
      vim.wait(50, function()
        return false
      end)
    end
    if M.watcher_handle then
      utils.log("watcher did not exit in time; forcing cleanup", vim.log.levels.WARN)
      pcall(function()
        M.watcher_handle:close()
      end)
      M.watcher_handle = nil
    end
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
