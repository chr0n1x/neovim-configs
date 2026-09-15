-- Shared base for harness adapters that do NOT support live edit-following (projects_dir() returns
-- nil). It provides the adapter interface with inert defaults so a stub harness can require it and
-- stay crash-free when it becomes the active harness, without re-declaring the same five no-op
-- functions in every stub. See docs/ai/agents/adapter-structure.md for the full interface; this base
-- only supplies the parts a non-following harness never reaches (the watcher stays off while
-- projects_dir() is nil). A stub composes it and overrides projects_dir() (and anything else that
-- diverges) - see crush/init.lua and pi/init.lua.
local M = {}

---No session to own: the watcher is off, so ownership is never actually queried.
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
