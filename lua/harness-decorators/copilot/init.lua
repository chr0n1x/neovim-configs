local utils = require("harness-decorators.utils")
local parser = require("harness-decorators.jsonl-parser")
local diff = require("harness-decorators.diff")
local stub = require("harness-decorators.stub-adapter")

local M = setmetatable({}, { __index = stub })

---Title color: purple.
M.title_color = "#aa78ff"

-- ==========================================================================
-- PATHS
-- ==========================================================================

function M.projects_dir()
  return (os.getenv("HOME") or "") .. "/.copilot/session-state"
end

---Session id is the parent dir of events.jsonl.
---@param jsonl_path string?
---@return string?
function M.session_id(jsonl_path)
  if not jsonl_path then
    return nil
  end
  return jsonl_path:match("([^/]+)/events%.jsonl$")
end

---Copilot's session id comes from the path, not line content, so return nil and let the
---watcher fall back to M.session_id(jsonl_path).
---@return string?
function M.session_id_from_lines()
  return nil
end

---Flat: watch the root (FSEvents and inotifywait -r see the per-session subdirs).
M.flat_sessions_dir = true

-- ==========================================================================
-- SESSION IDENTIFICATION
-- ==========================================================================

local function read_session_start_cwd(jsonl_path)
  local entry = utils.read_first_line_table(jsonl_path)
  if entry and entry.type == "session.start" then
    return entry.data and entry.data.context and entry.data.context.cwd
  end
  return nil
end

function M.extract_cwd(lines)
  return utils.scan_lines_for_field(lines, '"session.start"', function(entry)
    if entry.type == "session.start" then
      return entry.data and entry.data.context and entry.data.context.cwd
    end
    return nil
  end)
end

function M.session_ownership(nvim_cwd, lines, jsonl_path)
  return utils.session_ownership(nvim_cwd, lines, jsonl_path, M.extract_cwd, read_session_start_cwd)
end

function M.sidecar_name(session_id)
  return "copilot-events-session-" .. session_id
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
    return stub.NO_DIFF
  end
  local d = ev.data
  if d and d.arguments and d.arguments.old_str and d.arguments.new_str then
    return diff.format_full(d.arguments.old_str, d.arguments.new_str)
  end
  if d and d.arguments and d.arguments.new_str then
    return d.arguments.new_str
  end
  return stub.NO_EVENT_DIFF
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
    delta = parser.snippet(args.new_str)
  elseif args.new_str then
    delta = parser.snippet(args.new_str)
  elseif args.content then
    delta = parser.snippet(args.content)
  end

  local dedup_key = d.toolCallId and ("copilot-" .. d.toolCallId) or nil

  return parser.make_change_info(
    fp,
    operation,
    starting_line,
    delta,
    entry.id,
    entry.timestamp,
    d.toolCallId,
    dedup_key,
    line_number
  )
end

return M
