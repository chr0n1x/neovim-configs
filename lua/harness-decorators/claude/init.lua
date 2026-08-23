-- Claude Code harness adapter: session identification, JSONL dialect parsing,
-- and watcher path helpers for the claude LLM harness (the default). Loaded by
-- the generic modules (jsonl-parser, watcher) when the harness is not maki.
local utils = require("harness-decorators.utils")

local M = {}

---True when this Neovim session runs under the Claude Code harness.
function M.is_active()
  return utils.harness == "claude"
end

-- ==========================================================================
-- PATHS
-- ==========================================================================

---Directory containing Claude's per-project session JSONL dirs.
---@return string?
function M.projects_dir()
  return (os.getenv("HOME") or "") .. "/.claude/projects"
end

-- ==========================================================================
-- SESSION IDENTIFICATION
-- ==========================================================================

---Determine whether a JSONL session belongs to this Neovim instance.
---Returns "match", "mismatch", or "unknown".
---Claude: the cwd field on any line is authoritative; other sessions in the
---same project dir have a different cwd, so a mismatched cwd rules them out.
---@param nvim_cwd string? CWD of this Neovim instance (nil = unknown)
---@param lines string[] JSONL lines to inspect
---@return "match"|"mismatch"|"unknown"
function M.session_ownership(nvim_cwd, lines)
  if nvim_cwd then
    local cwd = M.extract_cwd(lines)
    if cwd and cwd ~= nvim_cwd then
      return "mismatch"
    end
  end
  -- A matching (or absent) cwd means this is our session.
  return "match"
end

---True when a reset command keeps the SAME jsonl file (only history is wiped).
---/clear does; /resume and /new switch to a different JSONL.
---@param cmd string The reset command text (e.g. "/clear")
---@return boolean
function M.is_same_file_reset(cmd)
  return cmd == "/clear"
end

-- ==========================================================================
-- TERMINAL MATCHING
-- ==========================================================================

---True if the buffer is Claude Code's terminal (matched by buffer name).
---@param buf number
---@return boolean
function M.is_terminal_buffer(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name:find("claude", 1, true) ~= nil
end

-- ==========================================================================
-- JSONL DIALECT
-- ==========================================================================

---Extract the session's cwd from Claude JSONL lines (cwd is a top-level field).
---@param lines string[]
---@return string?
function M.extract_cwd(lines)
  for _, line in ipairs(lines) do
    if line:find('"cwd"') then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.cwd then
        return entry.cwd
      end
    end
  end
  return nil
end

---Extract typed user message texts from Claude JSONL lines. Handles both the
---old format (promptSource:"typed") and current format (type:"user").
---@param lines string[]
---@return string[]
function M.extract_typed_messages(lines)
  local msgs = {}
  for _, line in ipairs(lines) do
    local is_candidate = (line:find('"promptSource"') and line:find('"typed"'))
      or (line:find('"type"') and line:find('"user"') and line:find('"content"'))
    if is_candidate then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.type == "user" and entry.message then
        local content = entry.message.content
        -- Old format: top-level promptSource:"typed" with string content.
        if entry.promptSource == "typed" and type(content) == "string" and #content >= 6 then
          msgs[#msgs + 1] = content
        -- Current format: role:"user" with string content (actual typed message).
        elseif entry.message.role == "user" and type(content) == "string" and #content >= 6 then
          msgs[#msgs + 1] = content
        -- Current format with list content: pull first text block.
        elseif entry.message.role == "user" and type(content) == "table" then
          for _, item in ipairs(content) do
            if type(item) == "table" and item.type == "text" and type(item.text) == "string" and #item.text >= 6 then
              msgs[#msgs + 1] = item.text
              break
            end
          end
        end
      end
    end
  end
  return msgs
end

---True if a typed message content is a session-resetting slash command.
---/resume and /new switch to a new JSONL; /clear keeps the same JSONL but wipes history.
---@param content string
---@return boolean
function M.is_reset_command(content)
  local trimmed = content:match("^%s*(.-)%s*$")
  return trimmed == "/resume" or trimmed == "/clear" or trimmed == "/new"
end

---Scan Claude JSONL lines for a session-resetting user command. Returns the
---command text ("/resume", "/clear", or "/new") or nil.
---@param lines string[]
---@return string?
function M.find_reset_command(lines)
  for _, line in ipairs(lines) do
    local is_user_line = (line:find('"promptSource"') and line:find('"typed"'))
      or (line:find('"type"') and line:find('"user"') and line:find('"content"'))
    if not is_user_line then
      goto continue
    end
    local ok, entry = pcall(vim.json.decode, line)
    if ok and entry and entry.type == "user" and entry.message then
      local user_text = nil
      -- Old format.
      if entry.promptSource == "typed" and type(entry.message.content) == "string" then
        user_text = entry.message.content
      -- Current format.
      elseif entry.message.role == "user" and type(entry.message.content) == "string" then
        user_text = entry.message.content
      end
      if user_text and M.is_reset_command(user_text) then
        return user_text:match("^%s*(.-)%s*$")
      end
    end
    ::continue::
  end
  return nil
end

-- ==========================================================================
-- TOOL RESULT PARSING
-- ==========================================================================

---Extract change_info from a toolUseResult (user-type response entry).
---@param entry table The decoded JSON object
---@param line_number? integer The 1-based line number in the JSONL file
local function parse_tool_use_result(entry, line_number)
  local tur = entry.toolUseResult
  if not tur then
    return
  end

  local fp = tur.filePath
  if not fp or utils.is_noise(fp) then
    return
  end

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
    starting_line = tur.structuredPatch[1].newStart or tur.structuredPatch[1].oldStart
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
  if not entry.message or not entry.message.content then
    return
  end

  for _, item in ipairs(entry.message.content) do
    if item.type == "tool_use" and item.name == "Edit" then
      local fp = item.input and item.input.file_path
      if fp and not utils.is_noise(fp) then
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

---Parse a Claude JSONL line for file changes. Handles both toolUseResult
---responses and tool_use invocations (Edit/Write calls). Returns the
---normalized change_info table or nil.
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
function M.parse_tool_result(line, line_number)
  -- Quick pre-filter: only parse lines that look like tool results or tool uses.
  local has_tool_result = line:find('"toolUseResult"')
  local has_tool_use = line:find('"type":"tool_use"')

  if not has_tool_result and not has_tool_use then
    return
  end

  local ok, entry = pcall(vim.json.decode, line)
  if not ok or not entry then
    return
  end

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
