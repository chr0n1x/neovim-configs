local M = {}

---Get the USER env var, warn and return "unknown-user" if not set.
local function get_user()
  local user = os.getenv("USER")
  if not user then
    -- Use vim.notify directly to avoid circular dep on utils.
    vim.notify("[claude.nvim] USER env var not set, using 'unknown-user'", vim.log.levels.WARN)
    return "unknown-user"
  end
  return user
end

---Derive the sidecar file path from a session ID.
---Format: /tmp/nvim.${USER}/${pid}-claude-events-session-<session-id>.jsonl
---@param session_id string
---@return string
function M.path(session_id)
  local user = get_user()
  local neovim_pid = tostring(vim.uv.os_getppid())
  local dir = string.format("/tmp/nvim.%s", user)
  return string.format("%s/%s-claude-events-session-%s.jsonl", dir, neovim_pid, session_id)
end

---Derive the sidecar file path from a pinned JSONL session path.
---@param jsonl_path string|nil
---@return string|nil
function M.path_from_jsonl(jsonl_path)
  if not jsonl_path then
    return nil
  end
  local session_id = jsonl_path:match("([^/]+)%.jsonl$")
  if not session_id then
    return nil
  end
  return M.path(session_id)
end

---Append a raw JSONL line to the sidecar file.
---@param sidecar_path string
---@param raw_line string
function M.append(sidecar_path, raw_line)
  if not sidecar_path then
    return
  end
  -- Ensure /tmp/nvim.$USER exists.
  local dir = sidecar_path:match("(.*/)[^/]+$")
  if dir then
    vim.uv.fs_mkdir(dir, 493) -- 0755
  end
  local f = io.open(sidecar_path, "a")
  if not f then
    return
  end
  f:write(raw_line, "\n")
  f:close()
end

---Look up the best event from a sidecar file matching uuid + timestamp (+ optional id).
---String matching is used as a fast pre-filter before full JSON decode.
---This avoids decoding every line in the sidecar, which keeps lookup O(n)
---with a very small constant for the majority of non-matching lines.
---@param sidecar_path string
---@param uuid string
---@param timestamp any
---@param id string|nil
---@return table|nil
function M.lookup(sidecar_path, uuid, timestamp, id)
  if not sidecar_path or not uuid then
    return nil
  end
  local f = io.open(sidecar_path, "r")
  if not f then
    return nil
  end

  ---Score an event by how much diff data it contains. Higher = richer.
  local function score(ev)
    if ev.toolUseResult then
      local tur = ev.toolUseResult
      if tur.structuredPatch then
        return 3
      end
      if tur.newString then
        return 2
      end
      if tur.content then
        return 1
      end
    end
    if ev.message and ev.message.content then
      for _, item in ipairs(ev.message.content) do
        if item.type == "tool_use" and item.input then
          if item.input.new_string then
            return 2
          end
          if item.input.content then
            return 1
          end
        end
      end
    end
    return 0
  end

  local best = nil
  local best_score = -1
  local ts_str = tostring(timestamp)

  for line in f:lines() do
    if not line:find(uuid, 1, true) then
      goto continue
    end
    if not line:find(ts_str, 1, true) then
      goto continue
    end
    if id and not line:find(id, 1, true) then
      goto continue
    end

    local ok, ev = pcall(vim.json.decode, line)
    if ok then
      local s = score(ev)
      if s > best_score then
        best = ev
        best_score = s
      end
    end
    ::continue::
  end
  f:close()
  return best
end

---Extract diff text from a matched sidecar event.
---@param ev table|nil
---@return string
function M.extract_diff(ev)
  if not ev then
    return "(no diff data available)"
  end

  local tur = ev.toolUseResult
  if tur and tur.structuredPatch and tur.structuredPatch[1] then
    local sp = tur.structuredPatch[1]
    local parts = {}
    if sp.oldLines or sp.newLines then
      table.insert(parts, string.format("%d -> %d lines", sp.oldLines or 0, sp.newLines or 0))
    end
    table.insert(parts, "") -- blank separator before diff
    -- The diff content lives in the `lines` array (+/-/space prefixed).
    -- Walk it tracking line numbers: additions advance the new counter,
    -- deletions advance the old counter, context advances both.
    if sp.lines and #sp.lines > 0 then
      local old_ln = sp.oldStart or 0
      local new_ln = sp.newStart or 0
      local numbered = {}
      for _, l in ipairs(sp.lines) do
        local first = l:sub(1, 1)
        if first == "+" then
          table.insert(numbered, string.format("%5d  %s", new_ln, l))
          new_ln = new_ln + 1
        elseif first == "-" then
          table.insert(numbered, string.format("%5d  %s", old_ln, l))
          old_ln = old_ln + 1
        else
          -- Context line: show new_ln so numbers are contiguous after additions.
          table.insert(numbered, string.format("%5d  %s", new_ln, l))
          old_ln = old_ln + 1
          new_ln = new_ln + 1
        end
      end
      table.insert(parts, table.concat(numbered, "\n"))
    end
    return table.concat(parts, "\n")
  end

  if tur and tur.newString then
    return tur.newString
  end

  if tur and tur.content then
    return tur.content
  end

  if ev.message and ev.message.content then
    for _, item in ipairs(ev.message.content) do
      if item.type == "tool_use" and item.input then
        if item.input.new_string then
          return item.input.new_string
        end
        if item.input.content then
          return item.input.content
        end
      end
    end
  end

  return "(event matched but contains no diff data)"
end

return M
