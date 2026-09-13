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

---Shorten a path for display. The harness CLI reads files itself, so the reference just
---needs to be unambiguous and short. Preference order:
---  1. cwd-relative (e.g. "lua/harness-decorators/claude/keymaps.lua") when the file is
---     under the current working dir - shortest and matches how you'd type it.
---  2. ~ collapse (e.g. "~/Code/kran/...") when under $HOME but not under cwd.
---  3. the full path otherwise.
---A directory that IS the cwd has no non-empty remainder in either step, so it falls
---through to the full absolute path - never the empty/"./" form that yields a bare "@".
---This is the single definition of display shortening; context-inject and the history picker
---both delegate here (see tests/utils_spec.lua). Callers apply their own prefix/decoration
---(the picker prepends "./", claude/crush append a trailing "/" for dirs) on top of this.
---@param file_path string
---@return string
function M.shorten_path(file_path)
  -- 1. cwd-relative. Strip the cwd prefix when the file lives under it, yielding a short
  --    relative path. Only accept when there's actually a remainder (a bare filename under
  --    cwd is fine too).
  local cwd = vim.uv.cwd()
  if cwd and cwd ~= "" then
    local bare_cwd = cwd:gsub("/+$", "")
    if bare_cwd ~= "" then
      local prefix = bare_cwd .. "/"
      if file_path:sub(1, #prefix) == prefix then
        local rel = file_path:sub(#prefix + 1)
        if rel ~= "" then
          return rel
        end
      end
    end
  end

  -- 2. ~ collapse for anything under $HOME.
  local home = vim.env.HOME
  if home and home ~= "" then
    local bare_home = home:gsub("/+$", "")
    if bare_home ~= "" then
      if file_path == bare_home then
        return "~"
      end
      -- Only shorten when the path is home + "/" + more, so /home/kran2/foo is NOT
      -- shortened when HOME=/home/kran (the char right after home must be a slash).
      local prefix = bare_home .. "/"
      if file_path:sub(1, #prefix) == prefix then
        return "~/" .. file_path:sub(#prefix + 1)
      end
    end
  end

  -- 3. Full path.
  return file_path
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

---Reset dedup state.
function M.reset_dedup()
  M.seen_keys = {}
end

-- ==========================================================================
-- TREE SELECTION
-- ==========================================================================

---Get the file(s) selected in the current tree plugin, safely.
---
---Wraps claudecode.nvim's get_selected_files_from_tree in a pcall: that function
---can throw when the tree window has been closed or recreated (it calls
---nvim_win_get_cursor on a stale win id -> E5108). Returning an error string keeps
---every harness's <C-t>/tree-add handler from crashing.
---@return table files List of file paths (empty on failure)
---@return string|nil err Error message if no selection or the lookup threw
function M.get_tree_selection()
  local ok, integrations = pcall(require, "claudecode.integrations")
  if not ok then
    return {}, "claudecode.integrations not available"
  end
  local ok2, files, err = pcall(integrations.get_selected_files_from_tree)
  if not ok2 then
    return {}, tostring(files)
  end
  return files or {}, err
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

---Map an extracted session cwd to the tri-state ownership verdict every harness's
---session_ownership must return. This is the single definition of the contract so all
---adapters agree: a known cwd that differs from this nvim's cwd is a definite "mismatch";
---a known cwd equal to it is a "match"; and no cwd evidence yet (cwd is nil) is
---"unknown" - leave as a candidate and retry on the next write rather than guessing.
---@param nvim_cwd string? CWD of this Neovim instance (assumed non-nil by callers).
---@param cwd string? The session's extracted cwd, or nil if no evidence yet.
---@return "match"|"mismatch"|"unknown"
function M.ownership_from_cwd(nvim_cwd, cwd)
  if cwd and cwd ~= nvim_cwd then
    return "mismatch"
  end
  if cwd == nvim_cwd then
    return "match"
  end
  return "unknown"
end

return M
