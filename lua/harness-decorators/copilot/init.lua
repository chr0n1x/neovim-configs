local utils = require("harness-decorators.utils")

local M = {}

function M.is_active()
  return utils.harness == "copilot"
end

-- ==========================================================================
-- PATHS
-- ==========================================================================

function M.projects_dir()
  return (os.getenv("HOME") or "") .. "/.copilot/session-state"
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
  if nvim_cwd then
    local cwd = M.extract_cwd(lines) or read_session_start_cwd(jsonl_path)
    if cwd and cwd ~= nvim_cwd then
      return "mismatch"
    end
    if cwd == nvim_cwd then
      return "match"
    end
  end
  return "unknown"
end

function M.is_same_file_reset(_cmd)
  return false
end

function M.sidecar_name(session_id)
  return "copilot-events-session-" .. session_id
end

-- ==========================================================================
-- TERMINAL MATCHING
-- ==========================================================================

function M.is_terminal_buffer(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name:find("copilot", 1, true) ~= nil
end

-- ==========================================================================
-- JSONL DIALECT
-- ==========================================================================

function M.extract_typed_messages(lines)
  local msgs = {}
  for _, line in ipairs(lines) do
    if line:find('"user.message"') then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.type == "user.message" then
        local content = entry.data and entry.data.content
        if type(content) == "string" and #content >= 6 then
          msgs[#msgs + 1] = content
        end
      end
    end
  end
  return msgs
end

function M.is_reset_command(_content)
  return false
end

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

local function find_starting_line(before, after)
  local before_lines = vim.split(before, "\n", { plain = true })
  local after_lines = vim.split(after, "\n", { plain = true })
  local max_len = math.min(#before_lines, #after_lines)
  for i = 1, max_len do
    if before_lines[i] ~= after_lines[i] then
      return i
    end
  end
  if #before_lines ~= #after_lines then
    return max_len + 1
  end
  return nil
end

local function diff_full_files(before, after)
  local before_lines = vim.split(before, "\n", { plain = true })
  local after_lines = vim.split(after, "\n", { plain = true })

  local prefix_len = 0
  local max_prefix = math.min(#before_lines, #after_lines)
  for i = 1, max_prefix do
    if before_lines[i] == after_lines[i] then
      prefix_len = i
    else
      break
    end
  end

  local suffix_len = 0
  local max_suffix = math.min(#before_lines, #after_lines) - prefix_len
  for i = 1, max_suffix do
    if before_lines[#before_lines - i + 1] == after_lines[#after_lines - i + 1] then
      suffix_len = i
    else
      break
    end
  end

  local numbered = {}
  local ctx_start = math.max(1, prefix_len - 2)
  for i = ctx_start, prefix_len do
    table.insert(numbered, string.format("%5d  %s", i, " " .. after_lines[i]))
  end
  for i = prefix_len + 1, #before_lines - suffix_len do
    table.insert(numbered, string.format("%5d  %s", i, "-" .. before_lines[i]))
  end
  for i = prefix_len + 1, #after_lines - suffix_len do
    table.insert(numbered, string.format("%5d  %s", i, "+" .. after_lines[i]))
  end
  local ctx_end = math.min(3, suffix_len)
  for i = 1, ctx_end do
    local new_idx = #after_lines - suffix_len + i
    table.insert(numbered, string.format("%5d  %s", new_idx, " " .. after_lines[new_idx]))
  end

  return numbered
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
    local numbered = diff_full_files(d.arguments.old_str, d.arguments.new_str)
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
    starting_line = find_starting_line(args.old_str, args.new_str)
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
