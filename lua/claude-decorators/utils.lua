local M = {}

-- ==========================================================================
-- RATE-LIMITED LOGGER
-- ==========================================================================

M.cooldown_ms = 3000
M.log_seen = {}

---Shorten a file path by replacing the CWD prefix with ".".
---@param fp string
---@return string
local function shorten_path(fp)
  local cwd = vim.fn.getcwd()
  -- Ensure the cwd ends with a separator for clean replacement.
  if not (cwd:sub(-1) == "/" or cwd:sub(-1) == "\\") then
    cwd = cwd .. package.config:sub(1, 1)
  end
  if fp:sub(1, #cwd) == cwd then
    return "./" .. fp:sub(#cwd + 2)
  end
  return fp
end

---Suppresses duplicate message prefixes within a cooldown window.
---@param msg string The message to log.
---@param level? number Log level (passed to vim.notify).
---@param notify_opts? table Options passed directly to vim.notify.
function M.log(msg, level, notify_opts)
  if not msg then return end
  local now = math.floor(vim.uv.hrtime() / 1000000)
  local key = msg
  local last = M.log_seen[key]
  if last and now - last < M.cooldown_ms then
    return
  end
  M.log_seen[key] = now
  local display_msg = shorten_path(msg)
  local handle = vim.notify(
    "[claude.nvim auto-follow] " .. display_msg,
    level or vim.log.levels.INFO,
    notify_opts
  )
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
