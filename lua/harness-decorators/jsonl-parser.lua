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

---Build a normalized change event. This is the SINGLE definition of the change_info schema - every
--per-harness parse_tool_result constructs its result through here, so adding or renaming a field is
--one edit (the watcher's dispatch_change autocmd data and edit-jump's store_edit_source both read
--from this shape). All fields are passed explicitly; nil is a valid value for any of them.
---@param file_path string? path the edit touched
---@param operation string "Edit"|"Create"
---@param starting_line? integer 1-based line the change starts at, or nil (early/line-less events)
---@param delta string short human-readable diff snippet
---@param event_uuid? string harness-native uuid of the source record
---@param event_timestamp? number|string harness-native timestamp
---@param event_id? string harness-native per-item id (tool-use id / maki entry id)
---@param dedup_key? string key for suppressing duplicate autocmds, or nil
---@param source_line? integer 1-based JSONL line the record came from
---@return table change_info
function M.make_change_info(
  file_path,
  operation,
  starting_line,
  delta,
  event_uuid,
  event_timestamp,
  event_id,
  dedup_key,
  source_line
)
  return {
    file_path = file_path,
    operation = operation,
    starting_line = starting_line,
    delta = delta,
    event_uuid = event_uuid,
    event_timestamp = event_timestamp,
    event_id = event_id,
    dedup_key = dedup_key,
    source_line = source_line,
  }
end

return M
