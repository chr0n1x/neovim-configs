-- Crush harness adapter. Implements the generic adapter interface (see
-- docs/ai/agents/adapter-structure.md) so the harness-agnostic modules (watcher,
-- jsonl-parser) can require it without crashing when crush is the active harness.
--
-- Status: STUB (no live edit-following). The shared watcher follows edits by
-- tailing per-session JSONL files and parsing the appended lines. crush keeps
-- everything in SQLite instead - .crush/crush.db in the project cwd, a `messages`
-- table whose `parts` column is a JSON blob per message - so there is no JSONL to
-- tail. Following crush's edits would mean generalizing the watcher to a
-- SQLite-polling data source (watch crush.db-wal, query rows past a checkpoint,
-- pull tool calls out of `parts`), which is out of scope for this barebones
-- setup.
--
-- Until then projects_dir() returns nil, which makes watcher.start() log
-- "live JSONL following disabled" and no-op cleanly. The remaining required
-- functions are inherited from the shared stub base (stub-adapter.lua) and are
-- never actually reached while projects_dir() is nil (the watcher never spawns,
-- so no writes are ever processed).
local M = setmetatable({}, { __index = require("harness-decorators.stub-adapter") })

-- ==========================================================================
-- PATHS
-- ==========================================================================

---crush has no JSONL sessions dir (it uses SQLite). Returning nil disables the
---watcher for this harness, gracefully.
---@return string?
function M.projects_dir()
  return nil
end

return M
