-- Copilot state adapter: work status + session label.
--
-- Status: copilot exposes turn lifecycle in its per-session events.jsonl. The
-- pid to session dir mapping goes through inuse.<pid>.lock files; a copilot
-- process can hold locks in several session dirs (resumed/switched sessions
-- leave stale ones), so the active session is the one whose events.jsonl was
-- most recently written, falling back to the newest lock. A trailing
-- "assistant.turn_start" with no following end means a turn is in progress.
-- The child check is unusable for copilot (helper subprocesses exist at rest),
-- so M.no_child_check = true.
--
-- Label: the session's summary from ~/.copilot/session-store.db, looked up by
-- session id (the session dir's basename). Needs lsqlite3; without it the label
-- is the 8-char session id.

local utils = require("harness-decorators.utils")

local M = {}

M.no_child_check = true

local function state_dir()
  return require("harness-decorators.copilot").projects_dir()
end

local function store_path()
  return (os.getenv("HOME") or "") .. "/.copilot/session-store.db"
end

---Map a copilot pid to its active session dir.
---@param pid number|string
---@return string?
local function session_dir(pid)
  local root = state_dir()
  if not vim.uv.fs_stat(root) then
    return nil
  end
  local locks = {}
  for name, type_ in vim.fs.dir(root, { depth = 2 }) do
    if type_ ~= "directory" and vim.fs.basename(name):match("^inuse%." .. pid .. "%.lock$") then
      locks[#locks + 1] = root .. "/" .. name
    end
  end
  -- Prefer the locked dir whose events.jsonl was most recently written; with no events anywhere,
  -- the newest lock wins.
  local lock = utils.newest_by_mtime(locks, function(l)
    return vim.fs.dirname(l) .. "/events.jsonl"
  end) or utils.newest_by_mtime(locks)
  return lock and vim.fs.dirname(lock) or nil
end

function M.inputs(pid, _cwd)
  local dir = session_dir(pid)
  local store = store_path()
  return {
    dir = dir,
    store = store,
    label_key = dir,
    label_paths = { store, store .. "-wal" },
  }
end

---Last turn marker in events.jsonl: the state set by the last turn_start/turn_end in the
---tail; non-marker lines are skipped.
---@param path string
---@return "working"|"idle"|nil
local function read_turn_state(path)
  return utils.read_tail_lines(path, 512 * 1024, function(line)
    -- Match the value (the quoted string), not the key: copilot writes the key with a space after
    -- the colon, so a compact-key pattern would never hit. Two plain finds because Lua patterns
    -- have no alternation (a "(start|end)" pattern never matches either word), and plain=true
    -- keeps the dot literal.
    if line:find('"assistant.turn_start"', 1, true) then
      return "working"
    elseif line:find('"assistant.turn_end"', 1, true) then
      return "idle"
    end
    return nil -- no marker on this line; keep the running state
  end)
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(pid, _cwd, inputs)
  local dir = (inputs or { dir = session_dir(pid) }).dir
  if not dir then
    return "unknown"
  end
  local st = read_turn_state(dir .. "/events.jsonl")
  if st then
    return st
  end
  -- A fresh session has no events file yet, so it is idle.
  return "idle"
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(pid, _cwd, inputs)
  local dir = (inputs or { dir = session_dir(pid) }).dir
  if not dir then
    return nil
  end
  local sid = vim.fs.basename(dir)
  -- Try the sqlite summary; fall back to the short id.
  local store = inputs and inputs.store or store_path()
  local db, close
  if inputs then
    inputs.label_cacheable = true
  end
  if vim.uv.fs_stat(store) then
    db, close = utils.sqlite_open_ro(store)
    if inputs then
      inputs.label_cacheable = db ~= nil
    end
  end
  if db then
    local ok_q, res = pcall(function()
      local stmt = db:prepare("SELECT summary FROM sessions WHERE id=?")
      stmt:bind(sid)
      return stmt:get()
    end)
    close()
    if inputs then
      inputs.label_cacheable = ok_q
    end
    if ok_q and type(res) == "string" and res ~= "" then
      return res
    end
  end
  return sid:sub(1, 8)
end

return M
