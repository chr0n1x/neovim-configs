-- Shared helpers for harness-decorators: logging, dedup, path and session utils.
local M = {}

---Which LLM harness this Neovim session uses. Used for the notify prefix.
M.harness = os.getenv("NVIM_LLM_HARNESS") or "claude"

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
  local prefix = "[" .. M.harness .. ".nvim auto-follow] "
  local handle = vim.notify(prefix .. display_msg, level or vim.log.levels.INFO, notify_opts)
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

---Legacy: kept for backwards compat, not used by the file watcher.
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
-- PATH AND SESSION HELPERS
-- ==========================================================================

---Check if a file path is noise (temp/swap files).
---@param file_path string?
---@return boolean
function M.is_noise(file_path)
  if type(file_path) ~= "string" or #file_path == 0 then
    return true
  end
  return file_path:match("%.tmp%d*$")
    or file_path:match("%.sw[npx]$")
    or file_path:match("~$")
    or file_path:match("^/proc/")
end

---Clamp a target line to [1, max_line] for cursor placement. Guards against
---deletions that removed the line (target past EOF) or empty buffers; the
---parser's starting_line already points at the changed line.
---@param starting_line number? Line from the change event
---@param max_line number Buffer/file line count to clamp against
---@return number? Line to place the cursor at, or nil if no starting_line
function M.clamp_line(starting_line, max_line)
  if type(starting_line) ~= "number" then
    return nil
  end
  local clamped = math.min(starting_line, max_line)
  return math.max(1, clamped)
end

---Extract the session ID from a JSONL file path. Harness-aware: an adapter may
---define `session_id(jsonl_path)` when its id isn't the filename stem (copilot
---stores <session-id>/events.jsonl, so the id is the parent dir). Falls back to
---the filename stem used by claude/maki (<session-id>.jsonl).
---@param jsonl_path string|nil
---@return string|nil
function M.extract_session_id(jsonl_path)
  if not jsonl_path then
    return nil
  end
  local ok, adapter = pcall(require, "harness-decorators." .. M.harness)
  if ok and adapter and adapter.session_id then
    local id = adapter.session_id(jsonl_path)
    if id then
      return id
    end
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
