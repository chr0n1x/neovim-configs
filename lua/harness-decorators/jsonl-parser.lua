-- Parses session JSONL files into normalized change events. The Claude Code and
-- maki dialects live in harness-decorators.claude and harness-decorators.maki;
-- this module only dispatches on the active harness (utils.harness).
local utils = require("harness-decorators.utils")

local M = {}

---Parse a JSONL line for file changes. Dispatches to the active harness adapter.
---Reads utils.harness live (not cached at load time) so a runtime harness switch
---(switch.lua) repoints parsing without requiring the module to be reloaded.
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
---Returns change_info table or nil.
function M.parse_tool_result(line, line_number)
  return require("harness-decorators." .. utils.harness).parse_tool_result(line, line_number)
end

return M
