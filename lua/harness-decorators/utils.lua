-- Shared helpers for harness-decorators: logging, dedup, path and session utils.
local M = {}

---The active harness name, owned by harness-decorators.active (required lazily: active requires
---utils while it loads).
---@return string
local function active_harness()
  return require("harness-decorators.active").get()
end

---The full-override command from <PREFIX>_COMMAND, or nil when unset or empty.
---@param prefix string upper-case harness name, e.g. "CLAUDE"
---@return string?
local function command_override(prefix)
  local cmd_env = os.getenv(prefix .. "_COMMAND") or ""
  if cmd_env ~= "" then
    return cmd_env
  end
  return nil
end

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
  local override = command_override(h)
  if override then
    return override
  end
  local model = os.getenv(h .. "_MODEL") or ""
  if model_flag and model ~= "" then
    return cli .. " " .. model_flag .. model
  end
  return cli
end

---Stop and close a libuv timer; safe on nil and on an already closed timer.
---@param timer uv.uv_timer_t?
---@return nil
function M.close_timer(timer)
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
  return nil
end

---Upper-case the first letter, e.g. "claude" -> "Claude".
---@param name string
---@return string
function M.capitalize(name)
  return name:sub(1, 1):upper() .. name:sub(2)
end

---Spawn command for a harness whose CLI name equals its name: `<CLI>_COMMAND` overrides
---everything; otherwise the bare CLI plus --provider from NVIM_LLM_HARNESS_<CLI>_PROVIDER_NAME
---and --model from LLAMA_DEFAULT_MODEL when set.
---@param cli string e.g. "pi"
---@return string command
function M.provider_command(cli)
  local c = cli:upper()
  local override = command_override(c)
  if override then
    return override
  end
  local cmd = cli
  local provider = os.getenv("NVIM_LLM_HARNESS_" .. c .. "_PROVIDER_NAME") or ""
  if provider ~= "" then
    cmd = cmd .. " --provider " .. provider
  end
  local model = os.getenv("LLAMA_DEFAULT_MODEL") or ""
  if model ~= "" then
    cmd = cmd .. " --model " .. model
  end
  return cmd
end

-- The harness-decorators dir (parent of this file). list_harnesses scans it for sibling harness dirs.
local this_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

---Sibling dirs with env.lua + keymaps.lua: the roster of harnesses every other module derives from.
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

-- command_executable answers per executable name, valid while $PATH is unchanged. Each PATH search
-- costs tens of ms, and the statusline poll asks about every harness on every round.
--
--   { path = "/usr/local/bin:/usr/bin:/bin", answers = { claude = true, pig = false } }
--
-- A PATH change empties answers.
local executable_cache = { path = nil, answers = {} }

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
  if executable_cache.path ~= vim.env.PATH then
    executable_cache = { path = vim.env.PATH, answers = {} }
  end
  local answer = executable_cache.answers[exe]
  if answer == nil then
    answer = vim.fn.executable(exe) == 1
    executable_cache.answers[exe] = answer
  end
  return answer
end

---Decode the first line containing `needle` for which `extract(entry)` returns non-nil.
---The needle is a cheap pre-filter so non-matching lines are never decoded.
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
---seconds. Used by the cwd-keyed label adapters (maki, pi): a fresh session started in a dir
---that already has older ones must not be labelled with the previous one, so the match is by
---open time rather than "newest file". `time_of(path)` returns the candidate unix time, or nil
---to skip the path. Returns nil when nothing is close enough.
---@param dir string
---@param opened_at number? unix time this terminal instance was opened; non-number returns nil
---@param tolerance number max |candidate - opened_at| in seconds
---@param time_of fun(path: string): number? candidate time for a path, or nil to skip it
---@return string? best_path
function M.pick_jsonl_by_time(dir, opened_at, tolerance, time_of)
  if type(opened_at) ~= "number" then
    return nil
  end
  local best, best_dt = nil, math.huge
  for name in vim.fs.dir(dir) do
    if name:match("%.jsonl$") then
      local path = dir .. "/" .. name
      local t = time_of(path)
      if t then
        local dt = math.abs(t - opened_at)
        if dt <= tolerance and dt < best_dt then
          best, best_dt = path, dt
        end
      end
    end
  end
  return best
end

---The path with the newest mtime; the first wins a tie. Paths whose stat target is missing are
---skipped, so the result is nil when none exist.
---@param paths string[]
---@param stat_path_fn? fun(path: string): string maps a path to the file whose mtime counts
---@return string?
function M.newest_by_mtime(paths, stat_path_fn)
  local best, best_m = nil, -1
  for _, path in ipairs(paths) do
    local st = vim.uv.fs_stat(stat_path_fn and stat_path_fn(path) or path)
    local m = st and st.mtime.sec or -1
    if m > best_m then
      best, best_m = path, m
    end
  end
  return best
end

---Decode the first line of a JSONL file, or nil. Callers check the record type themselves.
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

local sqlite_missing = false

---lsqlite3 from package.loaded, else one require per session. A failed require is not stored in
---package.loaded, so its result is remembered here; a module placed in package.loaded later still wins.
---@return table?
local function lsqlite3()
  local loaded = package.loaded["lsqlite3"]
  if type(loaded) == "table" then
    return loaded
  end
  if sqlite_missing then
    return nil
  end
  local ok, sqlite = pcall(require, "lsqlite3")
  if ok and type(sqlite) == "table" then
    return sqlite
  end
  sqlite_missing = true
  return nil
end

function M._reset_sqlite()
  sqlite_missing = false
end

---Open a SQLite db read-only through lsqlite3, leaving a live WAL db undisturbed.
---@param path string
---@return table? db
---@return function|string close_or_err close function, or an error when lsqlite3 or the open fails
function M.sqlite_open_ro(path)
  local sqlite = lsqlite3()
  if not sqlite then
    return nil, "lsqlite3 not available"
  end
  local ok_db, db = pcall(function()
    return sqlite.open("file:" .. path .. "?mode=ro", true)
  end)
  if not ok_db or type(db) ~= "table" then
    return nil, "open failed: " .. tostring(db)
  end
  return db,
    function()
      pcall(function()
        if type(db.close) == "function" then
          db:close()
        end
      end)
    end
end

---Decode a whole JSON file, or nil when it is missing, empty, invalid, or not an object/array.
---@param path string
---@return table?
function M.read_json_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then
    return nil
  end
  local ok, e = pcall(vim.json.decode, data)
  if ok and type(e) == "table" then
    return e
  end
  return nil
end

---Call fn on each complete line in the last max_bytes; returns the last non-nil result.
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

---The complete lines in the max_bytes ending at byte `size`, and the absolute byte offset where
---the first of them starts. A tail that starts mid-line skips that partial line; a truncated tail
---with no newline has no complete line and returns {} with offset `size`.
---@param path string
---@param max_bytes number cap on bytes read
---@param size? integer end of the range read (default: the current file size)
---@return string[]? lines nil when the file cannot be opened
---@return integer? base_offset
function M.tail_complete_lines(path, max_bytes, size)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  size = size or f:seek("end")
  local start = math.max(0, size - max_bytes)
  f:seek("set", start)
  local chunk = f:read(size - start) or ""
  f:close()
  local base = start
  if start > 0 then
    local nl = chunk:find("\n", 1, true)
    if not nl then
      return {}, size
    end
    base = start + nl
    chunk = chunk:sub(nl + 1)
  end
  local lines = {}
  for line in chunk:gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines, base
end

-- ==========================================================================
-- RATE-LIMITED LOGGER
-- ==========================================================================

M.cooldown_ms = 3000
M.log_seen = {}

---Shorten a file path by replacing the home directory with "~".
---@param fp string
---@return string
local function collapse_home(fp)
  local home = os.getenv("HOME")
  if home then
    local home_prefix = home .. "/"
    if fp:sub(1, #home_prefix) == home_prefix then
      return "~/" .. fp:sub(#home_prefix + 1)
    end
  end
  return fp
end

---Shorten a path for display: ~ under $HOME, else the absolute path. Absolute so the harness
---resolves it whatever its cwd. Callers add their own prefix/suffix decoration.
---@param file_path string
---@return string
function M.shorten_path(file_path)
  -- Absolutize relative input (e.g. an expanded `%`).
  if file_path and file_path:sub(1, 1) ~= "/" then
    file_path = vim.fn.fnamemodify(file_path, ":p")
  end

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

  return file_path
end

---Drops a message repeated within cooldown_ms.
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
  local display_msg = collapse_home(msg)
  local prefix = "[" .. active_harness() .. ".nvim auto-follow] "
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

---Get the file(s) selected in the current tree plugin, via tree-select.
---pcall: a stale tree window can throw.
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
  local id = require("harness-decorators." .. active_harness()).session_id(jsonl_path)
  if id then
    return id
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

---Tri-state ownership verdict from a session's cwd: "match", "mismatch", or "unknown"
---when there is no cwd evidence yet (retry on the next write).
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

---Shared body of every adapter's session_ownership: unknown without an nvim cwd, else the cwd
---found in `lines` (falling back to read_first_cwd(jsonl_path), when given) judged by
---ownership_from_cwd.
---@param nvim_cwd string? CWD of this Neovim instance (nil = unknown)
---@param lines string[] JSONL lines to inspect
---@param jsonl_path string? Full path of the session JSONL
---@param extract_cwd fun(lines: string[]): string?
---@param read_first_cwd? fun(jsonl_path: string?): string? fallback reading the cwd from the file's first line
---@return "match"|"mismatch"|"unknown"
function M.session_ownership(nvim_cwd, lines, jsonl_path, extract_cwd, read_first_cwd)
  if not nvim_cwd then
    return "unknown"
  end
  local cwd = extract_cwd(lines)
  if not cwd and read_first_cwd then
    cwd = read_first_cwd(jsonl_path)
  end
  return M.ownership_from_cwd(nvim_cwd, cwd)
end

-- utils.harness reads and writes the value owned by harness-decorators.active.
setmetatable(M, {
  __index = function(_, k)
    if k == "harness" then
      return active_harness()
    end
  end,
  __newindex = function(t, k, v)
    if k == "harness" then
      require("harness-decorators.active").set(v)
    else
      rawset(t, k, v)
    end
  end,
})

return M
