-- Parses session JSONL files into normalized change events. The Claude Code and
-- maki dialects live in harness-decorators.claude and harness-decorators.maki;
-- this module only dispatches on the active harness (utils.harness).
local utils = require("harness-decorators.utils")

local M = {}

---Which LLM harness this Neovim session uses. Selects the JSONL dialect to parse.
M.harness = utils.harness

---Parse a JSONL line for file changes. Dispatches to the active harness adapter.
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
---Returns change_info table or nil.
function M.parse_tool_result(line, line_number)
  return require("harness-decorators." .. M.harness).parse_tool_result(line, line_number)
end

return M
