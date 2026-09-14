-- Crush state adapter: work status + session label, ported from the tmux
--picker (crush branches of pane_status/session_label).
--
-- Status: crush keeps a per-project SQLite db at <cwd>/.crush/crush.db. Only
--assistant messages ever get a finished_at; tool/user rows stay NULL. At rest
--the newest message is a finished assistant; mid-turn it's an unfinished row
--(streaming assistant, or a tool/user row awaiting a reply). So the newest
--message having finished_at NULL = turn in progress = working. This catches
--pure text generation, which the child check misses.
--
-- Label: the most recently updated session's title from the same db. Read-only
--open so the live WAL db isn't disturbed. Needs lsqlite3; without it both
--status and label degrade (status falls through to the child check).

local M = {}

local missing_reader_notified = false

local function notify_missing_reader()
  if missing_reader_notified then
    return
  end
  missing_reader_notified = true
  vim.notify("crush: install sqlite3 or lsqlite3 to show session details", vim.log.levels.WARN)
end

function M._reset()
  missing_reader_notified = false
end

---@param cwd string
---@return string?
local function db_path(cwd)
  if not cwd or cwd == "" then
    return nil
  end
  local p = cwd .. "/.crush/crush.db"
  if vim.uv.fs_stat(p) then
    return p
  end
  return nil
end

---Open the db read-only. Returns (db, close_fn) or (nil, err).
---@param path string
local function open_ro(path)
  local ok_sqlite, sqlite = pcall(require, "lsqlite3")
  if not ok_sqlite or type(sqlite) ~= "table" then
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

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, cwd)
  local db_path_ = db_path(cwd)
  if not db_path_ then
    return "unknown" -- no project db: let the child check decide
  end
  local db, close = open_ro(db_path_)
  if not db then
    return "unknown"
  end
  local ok, finished_null = pcall(function()
    local stmt = db:prepare("SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1")
    local row = stmt:get()
    return row ~= nil and row[1] == nil
  end)
  close()
  if not ok then
    return "unknown"
  end
  if finished_null then
    return "working"
  end
  return "idle"
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(_pid, cwd)
  local db_path_ = db_path(cwd)
  if not db_path_ then
    return nil
  end
  local db, close = open_ro(db_path_)
  if not db then
    return nil
  end
  local ok, title = pcall(function()
    local stmt = db:prepare("SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1")
    local row = stmt:get()
    if row and row[1] and row[1] ~= "" then
      return row[1]
    end
    return nil
  end)
  close()
  if ok and type(title) == "string" then
    return title
  end
  return nil
end

---@param pid number|string
---@param cwd string
---@return string?
function M.session_id(_pid, cwd)
  local db_path_ = db_path(cwd)
  if not db_path_ then
    return nil
  end
  local db, close = open_ro(db_path_)
  if db then
    local ok, session_id = pcall(function()
      local stmt = db:prepare("SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1")
      local row = stmt:get()
      return row and row[1] or nil
    end)
    close()
    if ok and type(session_id) == "string" and session_id ~= "" then
      return session_id
    end
  end
  if vim.fn.executable("sqlite3") ~= 1 then
    notify_missing_reader()
    return nil
  end
  local result = vim
    .system({
      "sqlite3",
      "-readonly",
      db_path_,
      "SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1",
    }, { text = true })
    :wait()
  if result.code == 0 then
    local session_id = result.stdout:match("^%s*(.-)%s*$")
    if session_id ~= "" then
      return session_id
    end
  end
  return nil
end

return M
