-- Pi harness adapter (pi.dev / @earendil-works/pi-coding-agent). Implements the
-- generic adapter interface (see docs/ai/agents/adapter-structure.md) so the
-- harness-agnostic modules (watcher, jsonl-parser) can require it without
-- crashing when pi is the active harness.
--
-- Status: STUB (no live edit-following), by choice - this is the barebones scope.
--
-- Unlike crush (SQLite), pi DOES write JSONL sessions, so a real adapter is
-- feasible later. The on-disk layout is Claude-like:
--   ~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl
-- The first line is a header: {"type":"session","version":N,"id":..,"cwd":..},
-- so session_ownership/pinning could be read straight from `cwd` (the maki
-- pattern). Edit-following additionally needs pi's tool_use/edit record shape,
-- which wasn't reverse-engineered here (no non-errored local edit session to
-- sample). To upgrade later: point projects_dir() at ~/.pi/agent/sessions and
-- implement session_ownership()/extract_cwd() from the header, then
-- parse_tool_result() from a real pi edit session.
--
-- While projects_dir() returns nil, watcher.start() logs "live JSONL following
-- disabled" and no-ops; the remaining required functions are never reached.
local M = {}

---True when this Neovim session runs under the pi harness.
function M.is_active()
  return require("harness-decorators.utils").harness == "pi"
end

-- ==========================================================================
-- PATHS
-- ==========================================================================

---Barebones: return nil so the watcher stays off for pi. (A real adapter would
---return os.getenv("HOME") .. "/.pi/agent/sessions".)
---@return string?
function M.projects_dir()
  return nil
end

-- ==========================================================================
-- ADAPTER INTERFACE (stubbed - unreachable while projects_dir() is nil)
-- ==========================================================================

---@return "match"|"mismatch"|"unknown"
function M.session_ownership(_nvim_cwd, _lines, _jsonl_path)
  return "unknown"
end

---@return string?
function M.find_reset_command(_lines)
  return nil
end

---@return boolean
function M.is_same_file_reset(_cmd)
  return false
end

---@return table?
function M.parse_tool_result(_line, _line_number)
  return nil
end

return M
