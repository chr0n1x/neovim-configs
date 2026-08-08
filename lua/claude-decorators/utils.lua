local M = {}

-- ==========================================================================
-- RATE-LIMITED LOGGER
-- ==========================================================================

M.cooldown_ms = 3000
M.log_seen = {}

---Shorten a file path by replacing the home directory with "~".
---@param fp string
---@return string
local function shorten_path(fp)
  local home = os.getenv("HOME")
  if home then
    local home_prefix = home .. "/"
    if fp:sub(1, #home_prefix) == home_prefix then
      return "~/" .. fp:sub(#home_prefix + 1)
    end
  end
  return fp
end

---Suppresses duplicate message prefixes within a cooldown window.
---@param msg string The message to log.
---@param level? number Log level (passed to vim.notify).
---@param notify_opts? table Options passed directly to vim.notify.
function M.log(msg, level, notify_opts)
  if not msg then
    return
  end
  local now = math.floor(vim.uv.hrtime() / 1000000)
  local key = msg
  local last = M.log_seen[key]
  if last and now - last < M.cooldown_ms then
    return
  end
  M.log_seen[key] = now
  local display_msg = shorten_path(msg)
  local handle = vim.notify("[claude.nvim auto-follow] " .. display_msg, level or vim.log.levels.INFO, notify_opts)
  return handle
end

---Reset logger state.
function M.reset_log()
  M.log_seen = {}
end

-- ==========================================================================
-- DEDUP TRACKING
-- ==========================================================================

M.seen_keys = {}

function M.key_seen(key)
  if not key then
    return false
  end
  return M.seen_keys[key] ~= nil
end

function M.mark_key_seen(key)
  if not key then
    return
  end
  M.seen_keys[key] = true
end

---Legacy: kept for backwards compat, not used by inotify watcher.
---@param tool_uses table Mutable ref to per-path tool tracking table.
function M.path_pos_seen(tool_uses, path, tool, pos)
  if not (path and tool and pos) then
    return false
  end
  tool_uses[path] = tool_uses[path] or {}
  tool_uses[path][tool] = tool_uses[path][tool] or {}
  return tool_uses[path][tool][pos] ~= nil
end

---Reset dedup state.
function M.reset_dedup()
  M.seen_keys = {}
end

-- ==========================================================================
-- SESSION ID EXTRACTION
-- ==========================================================================

---Extract the session ID from a JSONL file path.
---@param jsonl_path string|nil
---@return string|nil
function M.extract_session_id(jsonl_path)
  if not jsonl_path then
    return nil
  end
  return jsonl_path:match("([^/]+)%.jsonl$")
end

---Format epoch-ms timestamp as a human-readable date string.
---@param ts number epoch milliseconds
---@return string
function M.format_time(ts)
  local secs = math.floor(ts / 1000)
  return os.date("%b %d %Y %H:%M:%S", secs)
end

return M
