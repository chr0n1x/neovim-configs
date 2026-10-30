-- Maki harness adapter (see docs/ai/agents/adapter-structure.md). Handles session
-- identification only; the maki plugin (lua/edit-jump-nvim.lua) fires User HarnessEdit
-- on ToolDone, so parse_tool_result returns nil.
local utils = require("harness-decorators.utils")
local diff = require("harness-decorators.diff")
local stub = require("harness-decorators.stub-adapter")

local M = setmetatable({}, { __index = stub })

---Title color: light cerulean.
M.title_color = "#6eb9f0"

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

---Trailing bytes of a freshly-pinned session to scan on pin.
local PIN_TAIL_BYTES = 16384

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
    return stub.NO_DIFF
  end

  -- Maki Diff records: full-file before/after in d.Diff.
  local maki_diff = ev.d and ev.d.Diff
  if maki_diff and maki_diff.before and maki_diff.after then
    return diff.format_full(maki_diff.before, maki_diff.after)
  end

  return stub.NO_EVENT_DIFF
end

---Called by the watcher when it first pins this session. Reads the last PIN_TAIL_BYTES and
---passes them to the watcher's process_recovered_lines, then returns the byte offset of the
---first complete line as the new baseline (file_size when there is nothing to read). The
---recovered lines dispatch nothing, since parse_tool_result returns nil for maki.
---@param jsonl_path string
---@param file_size number
---@return number base_byte_offset
function M.on_pin(jsonl_path, file_size)
  local lines, base = utils.tail_complete_lines(jsonl_path, PIN_TAIL_BYTES, file_size)
  if not lines or #lines == 0 then
    return file_size
  end

  -- Negative source_line offset: the number of lines before the tail is unknown.
  require("harness-decorators.watcher").process_recovered_lines(lines, -#lines)

  return base
end

-- ==========================================================================
-- SESSION IDENTIFICATION
-- ==========================================================================

---Extract the session id from the header line's top-level "id" (it also equals the filename
---stem). nil when no line carries one, so the caller falls back to the path.
---@param lines string[]
---@return string?
function M.session_id_from_lines(lines)
  return utils.scan_lines_for_field(lines, '"id"', function(entry)
    if entry.t == "header" and type(entry.id) == "string" and #entry.id > 0 then
      return entry.id
    end
    return nil
  end)
end

---Read the cwd from the header line at the TOP of a maki session file.
---@param jsonl_path string?
---@return string?
function M.read_header_cwd(jsonl_path)
  local entry = utils.read_first_line_table(jsonl_path)
  if entry and entry.t == "header" and entry.cwd then
    return entry.cwd
  end
  return nil
end

---Extract the session's cwd from a header line among `lines` (session_ownership falls back
---to read_header_cwd, since a tail-only scan never sees the header).
---@param lines string[]
---@return string?
function M.extract_cwd(lines)
  return utils.scan_lines_for_field(lines, '"cwd"', function(entry)
    if entry.t == "header" and entry.cwd then
      return entry.cwd
    end
    return nil
  end)
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
  return utils.session_ownership(nvim_cwd, lines, jsonl_path, M.extract_cwd, M.read_header_cwd)
end

---True when a reset command keeps the SAME jsonl file (only history is wiped).
---/compact rewrites the same JSONL (archiving old turns); /new switches to a
---different one. Maki has no /clear.
---@param cmd string The reset command text (e.g. "/compact")
---@return boolean
function M.is_same_file_reset(cmd)
  return cmd == "/compact"
end

return M
