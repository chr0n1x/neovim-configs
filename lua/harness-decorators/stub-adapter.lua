-- Inert adapter defaults for harnesses with no edit following (projects_dir() nil).
local M = {}

---@return string?
function M.projects_dir()
  return nil
end

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
