local M = {}

-- ==========================================================================
-- RATE-LIMITED LOGGER
-- ==========================================================================

M.cooldown_ms = 3000
M.log_seen = {}

---Suppresses duplicate message prefixes within a cooldown window.
function M.log(msg, level)
  if not msg then return end
  local now = math.floor(vim.uv.hrtime() / 1000000)
  local key = msg:sub(1, 40)
  local last = M.log_seen[key]
  if last and now - last < M.cooldown_ms then
    return
  end
  M.log_seen[key] = now
  vim.notify("[claude.nvim auto-follow] " .. msg, level or vim.log.levels.INFO)
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
  if not key then return false end
  return M.seen_keys[key] ~= nil
end

function M.mark_key_seen(key)
  if not key then return end
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

return M
