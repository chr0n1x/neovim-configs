-- Parses session JSONL files into normalized change events. Each dialect lives in
-- its harness adapter (harness-decorators.<name>); this module only dispatches on
-- the active harness (harness-decorators.active).
local active = require("harness-decorators.active")

local M = {}

---Parse a JSONL line for file changes. Dispatches to the active harness adapter.
---Reads the active harness live (not cached at load time) so a runtime harness switch
---(switch.lua) repoints parsing without requiring the module to be reloaded.
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
---Returns change_info table or nil.
function M.parse_tool_result(line, line_number)
  return require("harness-decorators." .. active.get()).parse_tool_result(line, line_number)
end

---One-line preview of text for a change delta: newlines shown as a literal backslash-n, cut to 60 chars.
---@param s string
---@return string
function M.snippet(s)
  return (s:gsub("\n", "\\n"):sub(1, 60))
end

---Build a normalized change event. This is the SINGLE definition of the change_info schema - every
---per-harness parse_tool_result constructs its result through here, so adding or renaming a field is
---one edit (the watcher's dispatch_change autocmd data and edit-jump's store_edit_source both read
---from this shape). All fields are passed explicitly; nil is a valid value for any of them.
---
---  {
---    file_path = "/home/u/Code/app/lua/init.lua",
---    operation = "Edit",
---    starting_line = 42,
---    delta = "-local x = 1\\n+local x = 2",
---    event_uuid = "9b2f6c1e-5d1a-4c7e-9f3a-2b8d1e0c4a77",
---    event_timestamp = "2026-10-30T14:02:11.512Z",
---    event_id = nil,
---    dedup_key = "9b2f6c1e-5d1a-4c7e-9f3a-2b8d1e0c4a772026-10-30T14:02:11.512Z",
---    source_line = 118,
---  }
---
---starting_line is nil on an early (line-less) event; event_id is set only when the source
---record has a per-item id, and dedup_key is nil when the record carries no id to build it from.
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
