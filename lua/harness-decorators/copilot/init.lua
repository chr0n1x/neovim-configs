local utils = require("harness-decorators.utils")
local diff = require("harness-decorators.diff")

local M = {}

-- ==========================================================================
-- PATHS
-- ==========================================================================

function M.projects_dir()
  return (os.getenv("HOME") or "") .. "/.copilot/session-state"
end

---Copilot stores each session in its own directory:
---  <session-state>/<session-id>/events.jsonl
---so the JSONL filename is always "events" and the session id is the PARENT
---directory name. The generic filename-stem extraction (used by claude/maki,
---where the file itself is named <session-id>.jsonl) would collapse every
---copilot session to the id "events", cross-polluting edit history and the
---sidecar. Extract the parent dir instead.
---@param jsonl_path string?
---@return string?
function M.session_id(jsonl_path)
  if not jsonl_path then
    return nil
  end
  return jsonl_path:match("([^/]+)/events%.jsonl$")
end

---Copilot's session id is the parent dir of events.jsonl, which is a property of the PATH,
---not of any line's content - so there is nothing to extract from lines. Return nil so the
---watcher falls back to M.session_id(jsonl_path) (the path-based rule), keeping the Option B
---pin-by-session-id contract uniform across adapters.
---@param _lines string[]
---@return string?
function M.session_id_from_lines(_lines)
  return nil
end

---Session JSONLs are NOT at the top level (they sit one dir down in
---<session-state>/<id>/events.jsonl), but on macOS fswatch's FSEvents backend
---reports writes for the whole subtree of a watched path, so watching the
---session-state root directly still catches every session's events.jsonl -
---including session dirs created AFTER nvim started (the common "open nvim,
---then launch copilot" flow). This also avoids enumerating and watching the
---dozens of historical per-session dirs individually. On Linux the watcher uses
---inotifywait -r on projects_dir, which is recursive regardless of this flag.
M.flat_sessions_dir = true

---Copilot keeps events.jsonl open and appends to it, which fires inotify
---"modify" rather than "close_write". Subscribe to modify too so live edits are
---seen on Linux (macOS/fswatch uses --event Updated and is unaffected). Extra
---events are harmless: the watcher's byte-offset dedup makes redundant polls a
---cheap no-op.
---@return string
function M.inotify_events()
  return "close_write,moved_to,modify"
end

-- ==========================================================================
-- SESSION IDENTIFICATION
-- ==========================================================================

local function read_session_start_cwd(jsonl_path)
  if not jsonl_path then
    return nil
  end
  local f = io.open(jsonl_path, "r")
  if not f then
    return nil
  end
  local first = f:read("*l")
  f:close()
  if not first then
    return nil
  end
  local ok, entry = pcall(vim.json.decode, first)
  if ok and entry and entry.type == "session.start" then
    return entry.data and entry.data.context and entry.data.context.cwd
  end
  return nil
end

function M.extract_cwd(lines)
  for _, line in ipairs(lines) do
    if line:find('"session.start"') then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.type == "session.start" then
        return entry.data and entry.data.context and entry.data.context.cwd
      end
    end
  end
  return nil
end

function M.session_ownership(nvim_cwd, lines, jsonl_path)
  if not nvim_cwd then
    return "unknown"
  end
  local cwd = M.extract_cwd(lines) or read_session_start_cwd(jsonl_path)
  return utils.ownership_from_cwd(nvim_cwd, cwd)
end

function M.is_same_file_reset(_cmd)
  return false
end

function M.sidecar_name(session_id)
  return "copilot-events-session-" .. session_id
end

-- ==========================================================================
-- JSONL DIALECT
-- ==========================================================================

function M.find_reset_command(_lines)
  return nil
end

-- ==========================================================================
-- SIDECAR: DIFF SCORING AND EXTRACTION
-- ==========================================================================

function M.score_event(ev)
  local d = ev.data
  if d and d.toolName == "edit" and d.arguments then
    if d.arguments.old_str and d.arguments.new_str then
      return 3
    end
    if d.arguments.new_str then
      return 2
    end
  end
  return 0
end

function M.extract_diff(ev)
  if not ev then
    return "(no diff data available)"
  end
  local d = ev.data
  if d and d.arguments and d.arguments.old_str and d.arguments.new_str then
    local old_lines = vim.split(d.arguments.old_str, "\n", { plain = true })
    local new_lines = vim.split(d.arguments.new_str, "\n", { plain = true })
    local parts = { string.format("%d -> %d lines", #old_lines, #new_lines), "" }
    local numbered = diff.diff_full_files(d.arguments.old_str, d.arguments.new_str)
    if #numbered > 0 then
      table.insert(parts, table.concat(numbered, "\n"))
    end
    return table.concat(parts, "\n")
  end
  if d and d.arguments and d.arguments.new_str then
    return d.arguments.new_str
  end
  return "(event matched but contains no diff data)"
end

-- ==========================================================================
-- TOOL RESULT PARSING
-- ==========================================================================

function M.parse_tool_result(line, line_number)
  if not line:find('"tool.execution_start"') then
    return nil
  end
  if not (line:find('"edit"') or line:find('"create"')) then
    return nil
  end

  local ok, entry = pcall(vim.json.decode, line)
  if not ok or not entry then
    return nil
  end

  local d = entry.data
  if not d then
    return nil
  end

  local tool = d.toolName
  if tool ~= "edit" and tool ~= "create" then
    return nil
  end

  local args = d.arguments
  if not args then
    return nil
  end

  local fp = args.path
  if not fp or utils.is_noise(fp) then
    return nil
  end

  local operation = tool == "create" and "Create" or "Edit"
  local starting_line = nil
  local delta = ""

  if args.old_str and args.new_str then
    starting_line = diff.find_starting_line(args.old_str, args.new_str)
    delta = args.new_str:gsub("\n", "\\n"):sub(1, 60)
  elseif args.new_str then
    delta = args.new_str:gsub("\n", "\\n"):sub(1, 60)
  elseif args.content then
    delta = args.content:gsub("\n", "\\n"):sub(1, 60)
  end

  local dedup_key = d.toolCallId and ("copilot-" .. d.toolCallId) or nil

  return {
    file_path = fp,
    operation = operation,
    starting_line = starting_line,
    delta = delta,
    event_uuid = entry.id,
    event_timestamp = entry.timestamp,
    event_id = d.toolCallId,
    dedup_key = dedup_key,
    source_line = line_number,
  }
end

return M
