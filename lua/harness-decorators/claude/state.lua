-- Claude Code state adapter: work status + session label, ported from the tmux
--picker (tmux-agent-pick.sh pane_status/session_label claude branches).
--
-- Status: ~/.claude/sessions/<pid>.json carries a "status" field; "busy" =
--working. Missing/unreadable falls through to the shared child-process check
--(agent-state does that when we return "unknown").
--
-- Label: a user rename lives in the session file's "name" (nameSource absent or
--not "derived"); otherwise the ai-title from the project jsonl, looked up by
--sessionId.

local utils = require("harness-decorators.utils")

local M = {}

local function sessions_dir()
  return (os.getenv("HOME") or "") .. "/.claude/sessions"
end

local function projects_dir()
  return (os.getenv("HOME") or "") .. "/.claude/projects"
end

---Read the session file for a pid. Returns the decoded table or nil.
---@param pid number|string
---@return table?
local function read_session(pid)
  local f = io.open(sessions_dir() .. "/" .. tostring(pid) .. ".json", "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then
    return nil
  end
  local ok, entry = pcall(vim.json.decode, data)
  if ok and type(entry) == "table" then
    return entry
  end
  return nil
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(pid, _cwd)
  local entry = read_session(pid)
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

---Find the project jsonl for a session id (same find as the tmux script). The
--project dir is keyed by cwd, so the file can be anywhere under it; globpath's
--** matches recursively (findfile does not).
---@param session_id string
---@return string?
local function find_project_jsonl(session_id)
  local out = vim.fn.globpath(projects_dir(), "**/" .. session_id .. ".jsonl", true, true)
  if type(out) == "table" and #out > 0 then
    return out[1]
  end
  return nil
end

---Last ai-title in a jsonl (the tmux script greps '"ai-title"' | tail -1). Scans the tail and keeps
--the last line that carries an aiTitle, so the final value wins.
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
function M.label(pid, _cwd)
  local entry = read_session(pid)
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
  local proj = find_project_jsonl(sid)
  if not proj then
    return nil
  end
  return read_ai_title(proj)
end

return M
