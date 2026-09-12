-- Maki harness adapter. Implements the same interface as
-- harness-decorators.claude (see docs/ai/agents/adapter-structure.md) so the
-- generic modules (watcher, jsonl-parser) are harness-agnostic.
--
-- Status: session identification works (the watcher pins the right session and
-- the statusline shows it). Edit parsing is STUBBED - maki's JSONL dialect is
-- not implemented yet, so no notifications or jumps fire for maki edits. The
-- setup warning in harness-decorators.init tells the user this.
local utils = require("harness-decorators.utils")
local diff = require("harness-decorators.diff")

local M = {}

---True when this Neovim session runs under the maki harness.
function M.is_active()
  return utils.harness == "maki"
end

-- ==========================================================================
-- PATHS
-- ==========================================================================

---Directory containing maki's session JSONLs and cwd_latest.json. Mirrors
---maki's own state dir resolution (maki-storage/src/paths.rs): if ~/.maki
---exists it IS the state dir, otherwise XDG_STATE_HOME/maki. Old and new
---locations can coexist, so check both.
---@return string?
function M.sessions_dir()
  local home = os.getenv("HOME") or ""
  local xdg_state = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
  local candidates = {
    home .. "/.maki/sessions",
    xdg_state .. "/maki/sessions",
  }
  for _, dir in ipairs(candidates) do
    if vim.uv.fs_stat(dir) then
      return dir
    end
  end
  return nil
end

---Alias for the generic adapter interface: the directory to watch.
---@return string?
function M.projects_dir()
  return M.sessions_dir()
end

---Maki's session JSONLs live at the top level of the sessions dir (no
---per-project subdirs), so fswatch should watch the dir itself, non-recursively.
M.flat_sessions_dir = true

---Trailing bytes of a freshly-pinned session to scan on pin. Comfortably holds
---several full-file Diff records, capped so a long resumed session doesn't replay
---its whole history.
local PIN_TAIL_BYTES = 16384

---inotify events the watcher should subscribe to for this harness. Maki keeps its
---session JSONL open and appends to it, which fires "modify" on each write rather
---than "close_write". close_write+moved_to are kept for the tmp+rename pattern
---(/compact and session rewrites). Extra events are harmless: the watcher's
---byte-offset dedup makes a redundant poll a cheap no-op.
---@return string
function M.inotify_events()
  return "close_write,moved_to,modify"
end

---Sidecar filename for a session (without the .jsonl extension).
---@param session_id string
---@return string
function M.sidecar_name(session_id)
  return "maki-events-session-" .. session_id
end

---Score a sidecar event by how much diff data it contains. Higher = richer.
---@param ev table Decoded JSONL line
---@return integer score
function M.score_event(ev)
  -- Maki Diff records: full-file before/after in d.Diff.
  if ev.d and ev.d.Diff and ev.d.Diff.before and ev.d.Diff.after then
    return 3
  end
  return 0
end

---Extract diff text from a matched sidecar event (maki dialect).
---@param ev table|nil Decoded JSONL line
---@return string
function M.extract_diff(ev)
  if not ev then
    return "(no diff data available)"
  end

  -- Maki Diff records: full-file before/after in d.Diff.
  local maki_diff = ev.d and ev.d.Diff
  if maki_diff and maki_diff.before and maki_diff.after then
    local before_lines = vim.split(maki_diff.before, "\n", { plain = true })
    local after_lines = vim.split(maki_diff.after, "\n", { plain = true })
    local parts = {}
    table.insert(parts, string.format("%d -> %d lines", #before_lines, #after_lines))
    table.insert(parts, "") -- blank separator before diff
    local numbered = diff.diff_full_files(maki_diff.before, maki_diff.after)
    if #numbered > 0 then
      table.insert(parts, table.concat(numbered, "\n"))
    end
    return table.concat(parts, "\n")
  end

  return "(event matched but contains no diff data)"
end

---Called by the watcher when it first pins this session. Maki writes its JSONL in
---atomic bursts (write-to-temp + rename), so an edit made in the same burst as the
---pin sits below the "current size" baseline and would be missed. Read the last
---PIN_TAIL_BYTES, recover the very last recorded event(s) via the watcher's
---process_recovered_lines, and return the byte offset to use as the new baseline
---(start of the scanned region's first complete line). Returns file_size when
---there is nothing to recover.
---@param jsonl_path string
---@param file_size number
---@return number base_byte_offset
function M.on_pin(jsonl_path, file_size)
  local start = math.max(0, file_size - PIN_TAIL_BYTES)
  local f = io.open(jsonl_path, "r")
  if not f then
    return file_size
  end
  f:seek("set", start)
  local chunk = f:read(file_size - start)
  f:close()
  if not chunk or #chunk == 0 then
    return file_size
  end

  -- Byte offset (absolute) of the first complete line in the tail. If we started
  -- mid-line, skip to just after the next newline.
  local base = start
  if start > 0 then
    local nl = chunk:find("\n", 1, true)
    if not nl then
      return file_size -- no complete line in the tail; nothing to recover
    end
    base = start + nl -- byte just after that newline = start of first full line
    chunk = chunk:sub(nl + 1)
  end

  local lines = {}
  for line in chunk:gmatch("([^\r\n]+)") do
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    return file_size
  end

  -- We don't know how many lines precede the tail, so use a negative offset for
  -- source_line (display only); dedup keys are id-based and unaffected. The
  -- recovered events feed edit_sources and the sidecar exactly like live ones.
  require("harness-decorators.watcher").process_recovered_lines(lines, -#lines)

  return base
end

---Maki writes a cwd -> session-id map next to its session JSONLs. Returns the
---session ID for `cwd`, or nil if the file is missing/unreadable.
---@param cwd string
---@return string?
function M.session_for_cwd(cwd)
  local dir = M.sessions_dir()
  if not dir then
    return nil
  end
  local f = io.open(dir .. "/cwd_latest.json", "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  local ok, map = pcall(vim.json.decode, content)
  if ok and type(map) == "table" and map[cwd] then
    return map[cwd]
  end
  return nil
end

-- ==========================================================================
-- SESSION IDENTIFICATION
-- ==========================================================================

---Read the cwd from the header line at the TOP of a maki session file.
---@param jsonl_path string?
---@return string?
function M.read_header_cwd(jsonl_path)
  if not jsonl_path then
    return nil
  end
  local f = io.open(jsonl_path, "r")
  if not f then
    return nil
  end
  local first = f:read("*l")
  f:close()
  if not first then
    return nil
  end
  local ok, entry = pcall(vim.json.decode, first)
  if ok and entry and entry.t == "header" and entry.cwd then
    return entry.cwd
  end
  return nil
end

---Extract the session's cwd from maki JSONL lines, falling back to the header
---line at the TOP of the file (a tail-only scan never sees it).
---@param lines string[]
---@return string?
function M.extract_cwd(lines)
  for _, line in ipairs(lines) do
    if line:find('"cwd"') then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.t == "header" and entry.cwd then
        return entry.cwd
      end
    end
  end
  return nil
end

---Determine whether a JSONL session belongs to this Neovim instance.
---Returns "match", "mismatch", or "unknown".
---Maki: the header line at the top of the file carries the session's cwd. If it
---matches this nvim's cwd, the session is ours by definition (works even when
---the tail has no typed messages). A corrupted/unreadable header falls through
---to "unknown" so a later write can retry.
---@param nvim_cwd string? CWD of this Neovim instance (nil = unknown)
---@param lines string[] JSONL lines to inspect
---@param jsonl_path string? Full path of the session JSONL
---@return "match"|"mismatch"|"unknown"
function M.session_ownership(nvim_cwd, lines, jsonl_path)
  if not nvim_cwd then
    return "unknown"
  end
  local cwd = M.extract_cwd(lines) or M.read_header_cwd(jsonl_path)
  return utils.ownership_from_cwd(nvim_cwd, cwd)
end

---True when a reset command keeps the SAME jsonl file (only history is wiped).
---/compact rewrites the same JSONL (archiving old turns); /new switches to a
---different one. Maki has no /clear.
---@param cmd string The reset command text (e.g. "/compact")
---@return boolean
function M.is_same_file_reset(cmd)
  -- /compact archives old turns into the same JSONL; the pin survives.
  return cmd == "/compact"
end

-- ==========================================================================
-- RESET DETECTION (STUB)
-- ==========================================================================

---Scan maki JSONL lines for a session-resetting user command. Returns the
---command text ("/new" or "/compact") or nil.
---TODO(maki): implement - detect /new and /compact typed messages so session
---state can be cleared on reset. Not needed for basic pinning.
---@param lines string[]
---@return string?
function M.find_reset_command(_lines)
  return nil
end

-- ==========================================================================
-- TOOL RESULT PARSING
-- ==========================================================================

---Extract change_info from a Diff out record.
---@param entry table The decoded JSON object
---@param line_number? integer The 1-based line number in the JSONL file
local function parse_diff_out(entry, line_number)
  local d = entry.d
  if not d or not d.Diff then
    return nil
  end
  local maki_diff = d.Diff
  local fp = maki_diff.path
  if not fp or utils.is_noise(fp) then
    return nil
  end

  local starting_line = diff.find_starting_line(maki_diff.before, maki_diff.after)
  local before_count = #vim.split(maki_diff.before, "\n", { plain = true })
  local after_count = #vim.split(maki_diff.after, "\n", { plain = true })
  local delta = string.format("%d -> %d lines", before_count, after_count)

  return {
    file_path = fp,
    operation = "Edit",
    starting_line = starting_line,
    delta = delta,
    event_uuid = nil,
    event_timestamp = nil,
    event_id = entry.id,
    dedup_key = "maki-out-" .. tostring(entry.id),
    source_line = line_number,
  }
end

---Extract change_info from a tool_use msg record (early notification).
---@param entry table The decoded JSON object
---@param line_number? integer The 1-based line number in the JSONL file
local function parse_tool_use_msg(entry, line_number)
  local d = entry.d
  if not d or not d.content then
    return nil
  end
  for _, item in ipairs(d.content) do
    if item.type == "tool_use" and (item.name == "edit" or item.name == "multiedit") then
      local fp = item.input and item.input.path
      if fp and not utils.is_noise(fp) then
        local delta = ""
        if item.input.new_string then
          delta = item.input.new_string:gsub("\n", "\\n"):sub(1, 60)
        end
        return {
          file_path = fp,
          operation = "Edit",
          starting_line = nil,
          delta = delta,
          event_uuid = nil,
          event_timestamp = nil,
          event_id = item.id,
          dedup_key = "maki-" .. tostring(item.id),
          source_line = line_number,
        }
      end
    end
  end
  return nil
end

---Parse a maki JSONL line for file changes. Returns the normalized change_info
---table or nil. Handles both Diff out records (full-file before/after) and
---tool_use msg records (early notification without line info).
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
function M.parse_tool_result(line, line_number)
  local has_diff = line:find('"t":"out"') and line:find('"Diff"')
  local has_tool_use = line:find('"t":"msg"') and line:find('"tool_use"')

  if not has_diff and not has_tool_use then
    return nil
  end

  local ok, entry = pcall(vim.json.decode, line)
  if not ok or not entry then
    return nil
  end

  -- Prefer Diff records (have starting_line from before/after diff).
  if has_diff then
    return parse_diff_out(entry, line_number)
  end

  -- Fallback to tool_use invocation (no line info, but catches edits early).
  if has_tool_use then
    return parse_tool_use_msg(entry, line_number)
  end

  return nil
end

return M
