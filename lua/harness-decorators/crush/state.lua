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
local cli_sessions = {}

local function notify_missing_reader()
  if missing_reader_notified then
    return
  end
  missing_reader_notified = true
  vim.notify("crush: install sqlite3 or lsqlite3 to show session details", vim.log.levels.WARN)
end

function M._reset()
  missing_reader_notified = false
  cli_sessions = {}
end

local function query(db, sql)
  if not db then
    return nil, false
  end
  local ok, row = pcall(function()
    return db:prepare(sql):get()
  end)
  return ok and row or nil, ok
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
local function first_row(cwd, sql, inputs)
  if inputs then
    return query(inputs.db, sql)
  end
  local path = db_path(cwd)
  if not path then
    return nil, false
  end
  local db, close = utils.sqlite_open_ro(path)
  if not db then
    return nil, false
  end
  local row, ok = query(db, sql)
  close()
  if not ok then
    return nil, false
  end
  return row, true
end

local function cli_session_id(path)
  if not utils.command_executable("sqlite3") then
    notify_missing_reader()
    return nil
  end
  local cached = cli_sessions[path]
  if not cached then
    cached = {}
    cli_sessions[path] = cached
  end
  if not cached.pending then
    cached.pending = true
    local ok = pcall(vim.system, {
      "sqlite3",
      "-readonly",
      path,
      "SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1",
    }, { text = true }, function(result)
      cached.pending = false
      if result.code == 0 then
        local id = (result.stdout or ""):match("^%s*(.-)%s*$")
        cached.id = id ~= "" and id or nil
      end
    end)
    if not ok then
      cached.pending = false
    end
  end
  return cached.id
end

function M.inputs(_pid, cwd)
  local path = db_path(cwd)
  local inputs = { label_paths = path and { path, path .. "-wal" } or {} }
  if not path then
    return inputs
  end
  local db, close = utils.sqlite_open_ro(path)
  inputs.db = db
  inputs.close = db and close or nil
  local row = query(db, "SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1")
  local id = row and row[1]
  inputs.session_id = type(id) == "string" and id ~= "" and id or cli_session_id(path)
  inputs.label_key = inputs.session_id or path
  return inputs
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, cwd, inputs)
  local row, ok =
    first_row(cwd, "SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1", inputs)
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
function M.label(_pid, cwd, inputs)
  local row = first_row(cwd, "SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1", inputs)
  local title = row and row[1]
  if type(title) == "string" and title ~= "" then
    return title
  end
  return nil
end

---@param pid number|string
---@param cwd string
---@return string?
function M.session_id(pid, cwd, inputs)
  if inputs then
    return inputs.session_id
  end
  inputs = M.inputs(pid, cwd)
  if inputs.close then
    inputs.close()
  end
  return inputs.session_id
end

return M
