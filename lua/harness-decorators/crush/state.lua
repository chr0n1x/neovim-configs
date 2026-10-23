-- Crush state adapter: work status + session label.
--
-- Status: crush keeps a per-project SQLite db at <cwd>/.crush/crush.db. Only
-- assistant messages ever get a finished_at; tool/user rows stay NULL. At rest
-- the newest message is a finished assistant; mid-turn it's an unfinished row
-- (streaming assistant, or a tool/user row awaiting a reply). So the newest
-- message having finished_at NULL means working. This catches pure text
-- generation, which the child check misses.
--
-- Label: the most recently updated session's title from the same db. Read-only
-- open so the live WAL db isn't disturbed. Needs lsqlite3; without it both
-- status and label degrade (status falls through to the child check).

local utils = require("harness-decorators.utils")

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

---First row of `sql` against the project db.
---@param cwd string
---@param sql string
---@return table? row nil when there is no row
---@return boolean ok false when there is no db, no lsqlite3, or the query failed
local function first_row(cwd, sql)
  local path = db_path(cwd)
  if not path then
    return nil, false
  end
  local db, close = utils.sqlite_open_ro(path)
  if not db then
    return nil, false
  end
  local ok, row = pcall(function()
    return db:prepare(sql):get()
  end)
  close()
  if not ok then
    return nil, false
  end
  return row, true
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, cwd)
  local row, ok = first_row(cwd, "SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1")
  if not ok then
    return "unknown" -- no project db or reader: let the child check decide
  end
  if row ~= nil and row[1] == nil then
    return "working"
  end
  return "idle"
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(_pid, cwd)
  local row = first_row(cwd, "SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1")
  local title = row and row[1]
  if type(title) == "string" and title ~= "" then
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
  local row = first_row(cwd, "SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1")
  if row and type(row[1]) == "string" and row[1] ~= "" then
    return row[1]
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
