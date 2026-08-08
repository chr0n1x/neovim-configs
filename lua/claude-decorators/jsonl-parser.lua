local M = {}

---Check if a file path is noise (temp/swap files).
function M.is_noise(file_path)
  if type(file_path) ~= "string" or #file_path == 0 then return true end
  return file_path:match("%.tmp%d*$")
    or file_path:match("%.sw[npx]$")
    or file_path:match("~$")
    or file_path:match("^/proc/")
end

---Read the last `bytes` bytes of a file. Returns the tail string or nil.
function M.read_tail(path, bytes)
  if not path then return nil end
  bytes = bytes or 8192
  local f = io.open(path, "r")
  if not f then return nil end
  local stat = f:seek("end")
  if stat == 0 then
    f:close()
    return nil
  end
  local pos = math.max(1, stat - bytes)
  f:seek("set", pos)
  local tail = f:read("*a")
  f:close()
  return tail or nil
end

---Read the last non-empty line of a file. Returns nil on failure.
function M.read_last_line(path)
  local tail = M.read_tail(path, 8192)
  if not tail or #tail == 0 then return nil end

  local lines = {}
  for line in tail:gmatch("([^\r\n]*)\r?\n?") do
    if #line > 0 then lines[#lines + 1] = line end
  end
  return lines[#lines] or nil
end

---Extract change_info from a toolUseResult (user-type response entry).
---@param entry table The decoded JSON object
---@param line_number? integer The 1-based line number in the JSONL file
local function parse_tool_use_result(entry, line_number)
  local tur = entry.toolUseResult
  if not tur then return end

  local fp = tur.filePath
  if not fp or M.is_noise(fp) then return end

  -- Determine operation from tur.type or payload shape.
  local operation = "Edit" -- default
  if tur.type == "create" then
    operation = "Create"
  elseif tur.oldString and tur.newString then
    operation = "Edit"
  elseif tur.structuredPatch then
    operation = "Edit"
  end

  -- Extract starting line from structuredPatch.
  -- "create" events don't have line info — they create a new file.
  local starting_line = nil
  if tur.structuredPatch and tur.structuredPatch[1] then
    starting_line = tur.structuredPatch[1].newStart
      or tur.structuredPatch[1].oldStart
  end

  -- Build a delta string for logging.
  local delta = ""
  if tur.type == "create" then
    delta = tur.content:gsub("\n", "\\n"):sub(1, 60)
  elseif tur.oldString and tur.newString then
    delta = tur.newString:gsub("\n", "\\n"):sub(1, 60)
  elseif tur.structuredPatch and tur.structuredPatch[1] then
    local sp = tur.structuredPatch[1]
    delta = string.format("%d->%d lines", sp.oldLines or 0, sp.newLines or 0)
  end

  return {
    file_path = fp,
    operation = operation,
    starting_line = starting_line,
    delta = delta,
    event_uuid = entry.uuid,
    event_timestamp = entry.timestamp,
    event_id = nil,
    dedup_key = entry.uuid and (entry.uuid .. entry.timestamp) or nil,
    source_line = line_number,
  }
end

---Extract change_info from a tool_use (assistant-type invocation entry).
---These appear in the JSONL before the tool result is returned, so catching
---them enables faster jump-to-edit while the session is still active.
---Note: tool_use entries don't have line numbers — the structuredPatch with
---actual line ranges only arrives in the matching toolUseResult later.
---@param entry table The decoded JSON object
---@param line_number? integer The 1-based line number in the JSONL file
local function parse_tool_use(entry, line_number)
  if not entry.message or not entry.message.content then return end

  for _, item in ipairs(entry.message.content) do
    if item.type == "tool_use" and item.name == "Edit" then
      local fp = item.input and item.input.file_path
      if fp and not M.is_noise(fp) then
        local operation = item.name
        local starting_line = nil

        local delta = ""
        if item.input.new_string then
          delta = item.input.new_string:gsub("\n", "\\n"):sub(1, 60)
        elseif item.input.content then
          delta = item.input.content:gsub("\n", "\\n"):sub(1, 60)
        end

        return {
          file_path = fp,
          operation = operation,
          starting_line = starting_line,
          delta = delta,
          event_uuid = entry.uuid,
          event_timestamp = entry.timestamp,
          event_id = item.id,
          dedup_key = entry.uuid and (entry.uuid .. entry.timestamp .. item.id) or nil,
          source_line = line_number,
        }
      end
    end
  end
end

---Parse a JSONL line for file changes. Handles both toolUseResult responses
---and tool_use invocations (Edit/Write calls).
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
---Returns change_info table or nil.
function M.parse_tool_result(line, line_number)
  -- Quick pre-filter: only parse lines that look like tool results or tool uses.
  local has_tool_result = line:find('"toolUseResult"')
  local has_tool_use    = line:find('"type":"tool_use"')

  if not has_tool_result and not has_tool_use then return end

  local ok, entry = pcall(vim.json.decode, line)
  if not ok or not entry then return end

  -- Prefer toolUseResult (has line numbers from structuredPatch).
  if has_tool_result then
    return parse_tool_use_result(entry, line_number)
  end

  -- Fallback to tool_use invocation (no line numbers, but catches edits early).
  if has_tool_use then
    return parse_tool_use(entry, line_number)
  end
end

return M
