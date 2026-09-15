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
-- disabled" and no-ops; the remaining required functions are inherited from the
-- shared stub base (stub-adapter.lua) and are never reached.
local M = setmetatable({}, { __index = require("harness-decorators.stub-adapter") })

-- ==========================================================================
-- PATHS
-- ==========================================================================

---Barebones: return nil so the watcher stays off for pi. (A real adapter would
---return os.getenv("HOME") .. "/.pi/agent/sessions".)
---@return string?
function M.projects_dir()
  return nil
end

return M
