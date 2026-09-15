-- Pi live edit-following + session-state bridge (nvim side).
--
-- pi does not use the JSONL watcher other harnesses use. Instead a pi EXTENSION
-- (nvim-harness-follow.ts, symlinked into ~/.pi/agent/extensions) runs INSIDE pi and pushes
-- two kinds of events to THIS nvim over its RPC socket ($NVIM), both via M.ingest():
--   * "edit"    - on edit/write tool_result: fires the same `User HarnessEdit` autocmd the
--                 watcher would, so edit-jump.lua consumes it unchanged (jump to file:line).
--   * "session" - on session_start / agent_start / agent_settled / session_shutdown: the real
--                 session id + working/idle status + cwd. pi/state.lua reads this registry to
--                 report accurate status + a uuid label, instead of guessing from file mtimes.
--
-- The extension is the only place that can know pi's identity/status (it runs in-process);
-- macOS won't expose a process's env to nvim, which is why the file-mtime guess in pi/state.lua
-- exists as a fallback for pi run OUTSIDE nvim.
--
-- All the testable logic lives here (see tests/pi_follow_spec.lua); the .ts stays thin.
local M = {}

local EXT_NAME = "nvim-harness-follow.ts"

-- Session registry, populated by pushed "session" events. Keyed by session id, with a
-- cwd -> latest-session-id index so pi/state.lua (which is handed a cwd) can look up.
local sessions = {} -- [session_id] = { status, cwd, session_file, updated_at }
local by_cwd = {} -- [cwd] = session_id (latest start wins)

-- A pushed "working"/"idle" status older than this is treated as stale (unknown), so a pi that
-- crashed without a shutdown event does not show "working" forever.
local STALE_SEC = 300

-- ==========================================================================
-- EXTENSION INSTALL (symlink bootstrap)
-- ==========================================================================

---Absolute directory of THIS module (…/lua/harness-decorators/pi).
---@return string
local function this_dir()
  local src = debug.getinfo(1, "S").source
  local file = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(file, ":h")
end

---Real path of the extension source shipped in this repo (sibling .ts file).
---@return string
function M.source_path()
  local p = this_dir() .. "/" .. EXT_NAME
  return vim.uv.fs_realpath(p) or p
end

---Where pi discovers global extensions.
---@return string
function M.target_path()
  return vim.fn.expand("~/.pi/agent/extensions/" .. EXT_NAME)
end

---Idempotently symlink the extension into pi's extensions dir so pi loads it on startup.
---Only ever manages its own uniquely-named target: never clobbers a real file.
---@param opts? { source?: string, target?: string }
---@return string status "linked"|"exists"|"updated"|"skipped"|"error"
function M.ensure(opts)
  opts = opts or {}
  local source = opts.source or M.source_path()
  local target = opts.target or M.target_path()

  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")

  local st = vim.uv.fs_lstat(target)
  if not st then
    return vim.uv.fs_symlink(source, target) and "linked" or "error"
  end
  if st.type == "link" then
    if vim.uv.fs_readlink(target) == source then
      return "exists"
    end
    vim.uv.fs_unlink(target)
    return vim.uv.fs_symlink(source, target) and "updated" or "error"
  end
  return "skipped"
end

-- ==========================================================================
-- EDIT EVENTS
-- ==========================================================================

---Parse the 1-based starting line of a pi edit diff. pi's details.diff is already numbered:
---context lines are "  159 ..." (leading space, then the number), changed lines start with a sign
---then a space then the line number, e.g. "+ 163 new" / "- 165 gone". Returns the first changed
---line's number, or nil. The %s* between sign and number tolerates both "+ 3" (pi's real format)
---and a hypothetical "+3" with no gap.
---@param diff string?
---@return integer?
function M.starting_line_from_diff(diff)
  if type(diff) ~= "string" then
    return nil
  end
  for line in diff:gmatch("[^\n]+") do
    local n = line:match("^[+%-]%s*(%d+)")
    if n then
      return tonumber(n)
    end
  end
  return nil
end

---Fire the `User HarnessEdit` autocmd edit-jump.lua consumes, from a decoded edit event.
---@param data table
local function fire_edit(data)
  local file_path = data.file_path
  if type(file_path) ~= "string" or file_path == "" then
    return
  end
  local starting_line = data.starting_line or M.starting_line_from_diff(data.diff)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "HarnessEdit",
      data = {
        file_path = file_path,
        operation = data.operation or "Edit",
        starting_line = starting_line,
        delta = data.delta,
        source_line = nil,
        jsonl_path = data.session_file,
        event_uuid = data.session_id,
        event_timestamp = nil,
        event_id = nil,
      },
    })
  end)
end

-- ==========================================================================
-- SESSION EVENTS
-- ==========================================================================

---Record (or drop) a pushed session event.
---@param data table
local function record_session(data)
  local id = data.session_id
  if type(id) ~= "string" or id == "" then
    return
  end
  if data.phase == "shutdown" then
    sessions[id] = nil
    if data.cwd and by_cwd[data.cwd] == id then
      by_cwd[data.cwd] = nil
    end
    return
  end
  sessions[id] = {
    status = data.status,
    cwd = data.cwd,
    session_file = data.session_file,
    updated_at = os.time(),
  }
  if type(data.cwd) == "string" and data.cwd ~= "" then
    by_cwd[data.cwd] = id
  end
end

---The live session state for a cwd, or nil when none is known / it has gone stale.
---@param cwd string?
---@param now? integer unix time (injectable for tests; defaults to os.time())
---@return { session_id: string, status: string?, cwd: string?, session_file: string? }?
function M.session_for_cwd(cwd, now)
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end
  local id = by_cwd[cwd]
  local s = id and sessions[id]
  if not s then
    return nil
  end
  if (now or os.time()) - (s.updated_at or 0) > STALE_SEC then
    return nil
  end
  return { session_id = id, status = s.status, cwd = s.cwd, session_file = s.session_file }
end

---The short (first 8 chars) form of a session uuid, for statusline display.
---@param id string?
---@return string?
function M.short_uuid(id)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  return id:sub(1, 8)
end

---Test hook: clear the in-memory registry.
function M._reset()
  sessions = {}
  by_cwd = {}
end

-- ==========================================================================
-- RPC ENTRY POINT
-- ==========================================================================

---Entry point the pi extension calls via `--remote-expr luaeval(...)`. Receives a base64-encoded
---JSON payload with a `kind` discriminator ("edit" | "session") and dispatches. Fails soft on any
---malformed input.
---@param b64 string
function M.ingest(b64)
  local ok_dec, json = pcall(vim.base64.decode, b64)
  if not ok_dec or type(json) ~= "string" then
    return
  end
  local ok_json, data = pcall(vim.json.decode, json)
  if not ok_json or type(data) ~= "table" then
    return
  end
  if data.kind == "edit" then
    fire_edit(data)
  elseif data.kind == "session" then
    record_session(data)
  end
end

return M
