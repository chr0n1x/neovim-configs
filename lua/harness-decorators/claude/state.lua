-- Claude Code state adapter: work status + session label.
--
-- Status: ~/.claude/sessions/<pid>.json carries a "status" field; "busy" means
-- working. Missing/unreadable returns "unknown", so agent-state runs the shared
-- child-process check.
--
-- Label: a user rename lives in the session file's "name" (nameSource absent or
-- not "derived"); otherwise the ai-title from the project jsonl, looked up by
-- sessionId.

local utils = require("harness-decorators.utils")

local M = {}
local project_jsonls = {}

local function sessions_dir()
  return (os.getenv("HOME") or "") .. "/.claude/sessions"
end

local function projects_dir()
  return require("harness-decorators.claude").projects_dir()
end

---Read the session file for a pid. Returns the decoded table or nil.
---@param pid number|string
---@return table?
local function read_session(pid)
  return utils.read_json_file(sessions_dir() .. "/" .. tostring(pid) .. ".json")
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(pid, _cwd, inputs)
  local entry = (inputs or { entry = read_session(pid) }).entry
  if not entry then
    return "unknown" -- no session file yet: let the child check decide
  end
  if entry.status == "busy" then
    return "working"
  end
  if entry.status == nil or entry.status == "" then
    return "unknown" -- unreadable/missing field: fall through to child check
  end
  return "idle"
end

---Find the project jsonl for a session id. The project dir is keyed by cwd, so the file
---can be anywhere under it; globpath's ** matches recursively (findfile does not).
---@param session_id string
---@return string?
local function find_project_jsonl(session_id)
  local root = projects_dir()
  local key = root .. "/" .. session_id
  local cached = project_jsonls[key]
  if cached and vim.uv.fs_stat(cached) then
    return cached
  end
  local out = vim.fn.globpath(root, "**/" .. session_id .. ".jsonl", true, true)
  if type(out) == "table" and #out > 0 then
    project_jsonls[key] = out[1]
    return out[1]
  end
  return nil
end

function M.inputs(pid, _cwd)
  local entry = read_session(pid)
  local sid = entry and entry.sessionId
  local name = entry and entry.name
  local renamed = type(name) == "string" and name ~= "" and entry.nameSource ~= "derived"
  local project = not renamed and type(sid) == "string" and sid ~= "" and find_project_jsonl(sid) or nil
  local session = sessions_dir() .. "/" .. tostring(pid) .. ".json"
  return {
    entry = entry,
    project = project,
    label_key = sid or session,
    label_paths = { session, project },
  }
end

---Last ai-title in a jsonl; scans the tail so the final value wins.
---@param path string
---@return string?
local function read_ai_title(path)
  return utils.read_tail_lines(path, 256 * 1024, function(line)
    -- Match the value, not the key: claude writes "aiTitle": with a space after
    -- the colon, so a compact-key pattern would never hit. Only a real aiTitle line returns a
    -- non-nil title; anything else falls through to nil so an earlier match is NOT overwritten by a
    -- later non-title line (the caller keeps the last non-nil it saw).
    if line:find('"aiTitle"', 1, true) or line:find('"ai-title"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" and type(entry.aiTitle) == "string" then
        return entry.aiTitle
      end
    end
    return nil
  end)
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(pid, _cwd, inputs)
  local entry = (inputs or { entry = read_session(pid) }).entry
  if not entry then
    return nil
  end
  -- User rename wins.
  local name = entry.name
  if type(name) == "string" and name ~= "" and (entry.nameSource == nil or entry.nameSource ~= "derived") then
    return name
  end
  local sid = entry.sessionId
  if type(sid) ~= "string" or sid == "" then
    return nil
  end
  local proj = (inputs or { project = find_project_jsonl(sid) }).project
  if not proj then
    return nil
  end
  return read_ai_title(proj)
end

return M
