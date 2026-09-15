-- Shared helpers for harness-decorators: logging, dedup, path and session utils.
local M = {}

---Which LLM harness this Neovim session uses. Used for the notify prefix.
M.harness = os.getenv("NVIM_LLM_HARNESS") or "claude"

---Build a harness terminal command from its env overrides. Every per-harness env.lua shares this
---shape: honor <HARNESS>_COMMAND as a full override (wrapper script, extra flags), else append an
---optional model flag when <HARNESS>_MODEL is set, else run the bare CLI. Harnesses with no model
---flag (copilot/crush/pi) just pass model_flag = nil. The claude harness keeps its Ollama env
---side-effect inline and only uses this for the command string itself.
---@param harness string e.g. "claude" - uppercased to form the env var names
---@param cli string the bare CLI name, e.g. "claude"
---@param model_flag? string flag prefix before the model value, e.g. "--model " or "-m " (nil = none)
---@return string command
function M.command_for(harness, cli, model_flag)
  local h = harness:upper()
  local cmd_env = os.getenv(h .. "_COMMAND") or ""
  if cmd_env ~= "" then
    return cmd_env
  end
  local model = os.getenv(h .. "_MODEL") or ""
  if model_flag and model ~= "" then
    return cli .. " " .. model_flag .. model
  end
  return cli
end

-- The harness-decorators dir (parent of this file). list_harnesses scans it for sibling harness dirs.
local this_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

---List sibling directories that look like a harness (env.lua + keymaps.lua). This is the single
--source-of-truth roster for "which harnesses exist" - agent-state, switch, keymaps and the specs all
--derive from it, so adding a new harness dir requires no edits elsewhere.
---@return string[]
function M.list_harnesses()
  local found = {}
  local fd = vim.uv.fs_scandir(this_dir)
  if fd then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if ftype == "directory" then
        local dir = this_dir .. "/" .. name
        if vim.uv.fs_stat(dir .. "/env.lua") and vim.uv.fs_stat(dir .. "/keymaps.lua") then
          table.insert(found, name)
        end
      end
    end
  end
  table.sort(found)
  return found
end

---Check whether the first token of a command string is an executable on PATH.
---@param cmd string The full command (e.g. "claude --model foo" or "maki -m bar")
---@return boolean
function M.command_executable(cmd)
  if type(cmd) ~= "string" or cmd == "" then
    return false
  end
  local exe = cmd:match("^%S+")
  if not exe or exe == "" then
    return false
  end
  return vim.fn.executable(exe) == 1
end

---Scan a list of raw JSONL lines for the first one containing `needle`, decode it, and return what
--`extract(entry)` yields (or nil to keep scanning). Returns nil when no line matches. This is the
--shared shape behind every adapter's extract_cwd / session_id_from_lines: a cheap needle pre-filter
--avoids decoding lines that can't match, then the caller's guard + extraction runs on the decoded
--table. The needle and extraction are harness-specific; the loop/decode discipline is not.
---@param lines string[] raw JSONL lines
---@param needle string plain substring that must appear for a line to be considered
---@param extract fun(entry: table): any? decode-guard + field extraction; nil means "not this one"
---@return any?
function M.scan_lines_for_field(lines, needle, extract)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" then
        local v = extract(entry)
        if v ~= nil then
          return v
        end
      end
    end
  end
  return nil
end

---Pick the *.jsonl in `dir` whose candidate time best matches `opened_at`, within `tolerance`
--seconds. This is the shared "match a session to THIS terminal's open time" skeleton used by the
--cwd-keyed label adapters (maki, pi): a fresh session started in a dir that already has older ones
--must NOT be labelled with the previous one, so we match by open time rather than "newest file".
--`time_of(path)` returns the candidate unix time for a path (or nil to skip it - e.g. maki reads the
--header created_at and also rejects a cwd mismatch, pi uses the file mtime). Returns the best path,
--or nil when nothing is close enough (caller falls back to its own newest-file heuristic).
---@param dir string
---@param opened_at number? unix time this terminal instance was opened; non-number returns nil
---@param tolerance number max |candidate - opened_at| in seconds
---@param time_of fun(path: string): number? candidate time for a path, or nil to skip it
---@return string? best_path
function M.pick_jsonl_by_time(dir, opened_at, tolerance, time_of)
  if type(opened_at) ~= "number" then
    return nil
  end
  local d = vim.uv.fs_opendir(dir)
  if not d then
    return nil
  end
  local best, best_dt = nil, math.huge
  while true do
    local r = vim.uv.fs_readdir(d)
    if not r or type(r) ~= "table" or #r == 0 then
      break
    end
    local e = r[1]
    if not e or not e.name then
      break
    end
    -- Skip non-session files - do NOT break: readdir order is unspecified, so the session we need
    -- may come after a non-matching entry.
    if e.name:match("%.jsonl$") then
      local path = dir .. "/" .. e.name
      local t = time_of(path)
      if t then
        local dt = math.abs(t - opened_at)
        if dt <= tolerance and dt < best_dt then
          best, best_dt = path, dt
        end
      end
    end
  end
  vim.uv.fs_closedir(d)
  return best
end

---Read and decode the FIRST line of a JSONL file, returning the decoded table or nil. Reading only
--the first line keeps this cheap even for long sessions (the header/first-record lives at the top).
--Callers keep their own type guards on the returned table (e.g. `t == "header"`,
--`type == "session.start"`); this helper just does the open / read-first-line / pcall-decode.
---@param path string? nil or unreadable returns nil
---@return table?
function M.read_first_line_table(path)
  if not path then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local line = f:read("*l")
  f:close()
  if not line or line == "" then
    return nil
  end
  local ok, e = pcall(vim.json.decode, line)
  if ok and type(e) == "table" then
    return e
  end
  return nil
end

---Tail-scan reader shared by the per-harness label/status adapters. Reads at most `max_bytes` from
--the END of `path`, skips a possible partial first line (only when we actually truncated, so a small
--file never loses its first line), and calls `fn(line)` once per complete line in file order. fn
--returns the value to KEEP for that line, or nil to leave the running result unchanged - so callers
--implement "last matching record wins" (claude/maki titles) or "accumulate a state, last marker wins"
--(copilot turn state) without re-scanning. Returns the final result, or nil if no line ever produced
--one (or the file is missing/empty). The needle/predicate and accumulator live in the caller, not here.
---@param path string
---@param max_bytes number cap on bytes read from the end
---@param fn fun(line: string): any? per-line handler; nil means "no change to the running result"
---@return any?
function M.read_tail_lines(path, max_bytes, fn)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  f:seek("end")
  local size = f:seek()
  local chunk_size = math.min(size, max_bytes)
  f:seek("set", size - chunk_size)
  local chunk = f:read(chunk_size) or ""
  f:close()
  if chunk == "" then
    return nil
  end
  -- Skip a possible partial first line. Only when we truncated (size > chunk_size): a file smaller
  -- than the cap starts on a real line boundary and must not drop its first line.
  local nl = chunk:find("\n")
  if nl and size > chunk_size then
    chunk = chunk:sub(nl + 1)
  end
  local result
  for line in chunk:gmatch("[^\n]+") do
    local v = fn(line)
    if v ~= nil then
      result = v
    end
  end
  return result
end

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
---Delegates to our own neo-tree selector (harness-decorators/tree-select), which
---reads the live neo-tree state directly - no claudecode.nvim dependency. The whole
---call is wrapped in a pcall because reading a tree whose window was just closed or
---recreated can throw (a stale win id -> E5108). Returning an error string keeps every
---harness's <C-t>/tree-add handler from crashing.
---@return table files List of file paths (empty on failure)
---@return string|nil err Error message if no selection or the lookup threw
function M.get_tree_selection()
  local ok, files, err = pcall(require("harness-decorators.tree-select").get_selected)
  if not ok then
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
