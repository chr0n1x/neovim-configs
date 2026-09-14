-- Copilot state adapter: work status + session label, ported from the tmux
--picker (copilot_session_dir + pane_status/session_label copilot branches).
--
-- Status: copilot exposes turn lifecycle in its per-session events.jsonl. The
--pid -> session dir mapping goes through inuse.<pid>.lock files; a copilot
--process can hold locks in several session dirs (resumed/switched sessions
--leave stale ones), so the active session is the one whose events.jsonl was
--most recently written, falling back to the newest lock. A trailing
--"assistant.turn_start" with no following end = turn in progress = working.
--The child check is unusable for copilot (helper subprocesses exist at rest),
--so M.no_child_check = true.
--
-- Label: the session's summary from ~/.copilot/session-store.db, looked up by
--session id (the session dir's basename). Needs lsqlite3; without it the label
--falls back to the 8-char session id, same as the tmux script.

local M = {}

M.no_child_check = true

local function state_dir()
  return (os.getenv("HOME") or "") .. "/.copilot/session-state"
end

local function store_path()
  return (os.getenv("HOME") or "") .. "/.copilot/session-store.db"
end

---Map a copilot pid to its active session dir (ported from copilot_session_dir).
---@param pid number|string
---@return string?
local function session_dir(pid)
  local root = state_dir()
  if not vim.uv.fs_stat(root) then
    return nil
  end
  -- Collect inuse.<pid>.lock files at depth <= 2. fs_readdir needs a uv_dir handle.
  local locks = {}
  local function scan(dir, depth)
    if depth > 2 then
      return
    end
    local d = vim.uv.fs_opendir(dir)
    if not d then
      return
    end
    while true do
      local r = vim.uv.fs_readdir(d)
      if not r or type(r) ~= "table" or #r == 0 then
        break
      end
      local e = r[1]
      if not e or not e.name then
        break
      end
      local name = e.name
      local full = dir .. "/" .. name
      if e.type == "directory" then
        scan(full, depth + 1)
      elseif name:match("^inuse%." .. pid .. "%.lock$") then
        locks[#locks + 1] = full
      end
    end
    vim.uv.fs_closedir(d)
  end
  scan(root, 1)
  if #locks == 0 then
    return nil
  end
  -- Prefer the locked dir whose events.jsonl was most recently written.
  local best, best_m = nil, -1
  for _, lock in ipairs(locks) do
    local d = vim.fs.dirname(lock)
    local ev = vim.uv.fs_stat(d .. "/events.jsonl")
    local m = ev and ev.mtime.sec or -1
    if m > best_m then
      best, best_m = d, m
    end
  end
  if best then
    return best
  end
  -- No events anywhere: newest lock wins.
  local best_lock, best_lm = nil, -1
  for _, lock in ipairs(locks) do
    local st = vim.uv.fs_stat(lock)
    local m = st and st.mtime.sec or -1
    if m > best_lm then
      best_lock, best_lm = lock, m
    end
  end
  return best_lock and vim.fs.dirname(best_lock) or nil
end

---Last turn marker in events.jsonl (tail -n 400 | grep | tail -1 equivalent).
---@param path string
---@return "working"|"idle"|nil
local function read_turn_state(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  f:seek("end")
  local size = f:seek()
  -- 400 lines ~ generous tail; cap the bytes read.
  local chunk_size = math.min(size, 512 * 1024)
  f:seek("set", size - chunk_size)
  local chunk = f:read(chunk_size) or ""
  f:close()
  if chunk == "" then
    return nil
  end
  local state
  for line in chunk:gmatch("[^\n]+") do
    -- Match the value (the quoted string), not the key: copilot writes
    -- "assistant.turn_start" with a space after the colon, so a compact-key
    -- pattern would never hit. No alternation here: in this LuaJIT the bare
    -- word `end` inside (start|end) matches empty and the capture returns nil.
    -- plain=true: no pattern magic, so the dot is literal and needs no %. escape.
    if line:find('"assistant.turn_start"', 1, true) then
      state = "working"
    elseif line:find('"assistant.turn_end"', 1, true) then
      state = "idle"
    end
  end
  if state then
    return state
  end
  return nil -- no markers yet (fresh session)
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(pid, _cwd)
  local dir = session_dir(pid)
  if not dir then
    return "unknown"
  end
  local st = read_turn_state(dir .. "/events.jsonl")
  if st then
    return st
  end
  -- No events file yet (fresh session) = idle, same as the tmux script.
  return "idle"
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(pid, _cwd)
  local dir = session_dir(pid)
  if not dir then
    return nil
  end
  local sid = vim.fs.basename(dir)
  -- Try the sqlite summary; fall back to the short id (tmux-script parity).
  local ok_sqlite, sqlite = pcall(require, "lsqlite3")
  if ok_sqlite and type(sqlite) == "table" then
    local store = store_path()
    if vim.uv.fs_stat(store) then
      local ok_db, db = pcall(function()
        return sqlite.open("file:" .. store .. "?mode=ro", true)
      end)
      if ok_db and type(db) == "table" then
        local ok_q, res = pcall(function()
          local stmt = db:prepare("SELECT summary FROM sessions WHERE id=?")
          stmt:bind(sid)
          return stmt:get()
        end)
        pcall(function()
          if type(db) == "table" and type(db.close) == "function" then
            db:close()
          end
        end)
        if ok_q and type(res) == "string" and res ~= "" then
          return res
        end
      end
    end
  end
  return sid:sub(1, 8)
end

return M
