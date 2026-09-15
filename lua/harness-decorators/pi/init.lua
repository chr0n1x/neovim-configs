-- Pi harness adapter (pi.dev / @earendil-works/pi-coding-agent). Implements the
-- generic adapter interface (see docs/ai/agents/adapter-structure.md) so the
-- harness-agnostic modules (watcher, jsonl-parser) can require it without
-- crashing when pi is the active harness.
--
-- Status: STUB for edit-following (projects_dir() returns nil). The context keymaps
-- (<leader>ca / <C-t> / visual <leader>ca / <leader>cc / <leader>cr) ARE wired - see
-- pi/keymaps.lua. Only live JSONL edit-following is still stubbed.
--
-- Unlike crush (SQLite), pi DOES write JSONL sessions, so a real edit-following adapter
-- is feasible. The on-disk layout is Claude-like:
--   ~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<uuid>.jsonl
-- The first line is a header: {"type":"session","version":N,"id":..,"cwd":..}, so
-- session_ownership/extract_cwd read straight off `cwd` (the maki/claude pattern).
--
-- The edit-record shape HAS now been reverse-engineered from real sessions (the old
-- "no edit session to sample" blocker is gone). Entries are {"type":"message",
-- "message":{role,...}}. Edits look like:
--   * assistant toolCall block: {type:"toolCall", id, name:"edit"|"write", arguments:{path,...}}
--   * toolResult: {role:"toolResult", toolCallId, toolName, content:[{text}], details, isError}
--       - edit results carry details.diff: an ALREADY-numbered unified diff, e.g.
--         "+163   // ..." / "-165   if (...)" (sign BEFORE the line number - not maki's format)
--       - write results have details:null and text "Successfully wrote to <path>"
-- To upgrade: point projects_dir() at ~/.pi/agent/sessions (recursive - per-project
-- subdirs, NOT flat), keep session_ownership()/extract_cwd() reading the header cwd, and
-- implement parse_tool_result() by matching edit/write toolResult lines: pull the path from
-- the result text (or correlate toolCallId back to the toolCall's arguments.path) and the
-- starting_line from the first signed line number in details.diff. Then wire history_spec
-- back into pi/keymaps.lua.
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
