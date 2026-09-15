-- Pi state adapter: work status + session label.
--
-- Preferred source: the pi extension (nvim-harness-follow.ts) pushes session events into
-- pi/follow.lua while pi runs inside nvim, giving the REAL session id + working/idle status.
-- When that pushed state exists for the cwd, status/label use it directly - accurate status
-- (not "unknown") and a uuid label with no guessing.
--
-- Fallback (pi run OUTSIDE nvim, so nothing was pushed): pi keys its session dir off the cwd
-- (--<cwd>-- with the leading slash stripped and /, \, : turned into -). macOS won't expose a
-- process's env, so the exact session isn't reachable by pid; take the session file whose mtime
-- best matches the terminal's open time and derive the uuid from its filename (…_<uuid>.jsonl).
-- Status has no fallback signal, so it stays "unknown" (delegates to the shared child check).

local utils = require("harness-decorators.utils")

local M = {}

local function sessions_root()
  return (os.getenv("HOME") or "") .. "/.pi/agent/sessions"
end

---cwd -> pi session dir name (ported from the sed in the tmux script).
---@param cwd string
---@return string
local function dir_name(cwd)
  local s = cwd:match("^/(.*)$") or cwd
  s = s:gsub("/", "-"):gsub("\\", "-"):gsub(":", "-")
  return "--" .. s .. "--"
end

---The *.jsonl in `dir` whose mtime best matches the terminal's open time. A fresh session started
--in a dir that already has older ones must NOT be labelled with the previous one, so we match by
--open time rather than "newest file". Returns the path, or nil when nothing is close enough (caller
--falls back to newest_jsonl).
---@param dir string
---@param opened_at number? unix time this terminal instance was opened
---@return string?
local function jsonl_for_open(dir, opened_at)
  -- Tolerance: the file's first write lands within a second or two of snacks.open.
  return utils.pick_jsonl_by_time(dir, opened_at, 30, function(path)
    local st = vim.uv.fs_stat(path)
    return st and st.mtime.sec
  end)
end

---Most recently modified *.jsonl in a dir (ls -t | head -1 equivalent). Fallback when no session's
--mtime matches the terminal's open time.
---@param dir string
---@return string?
local function newest_jsonl(dir)
  local d = vim.uv.fs_opendir(dir)
  if not d then
    return nil
  end
  local best, best_m = nil, -1
  while true do
    local r = vim.uv.fs_readdir(d)
    if not r or type(r) ~= "table" or #r == 0 then
      break
    end
    local e = r[1]
    if not e or not e.name then
      break
    end
    if e.name:match("%.jsonl$") then
      local st = vim.uv.fs_stat(dir .. "/" .. e.name)
      local m = st and st.mtime.sec or -1
      if m > best_m then
        best, best_m = dir .. "/" .. e.name, m
      end
    end
  end
  vim.uv.fs_closedir(d)
  return best
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, cwd)
  -- Preferred: real status the extension pushed for this cwd (pi running in nvim).
  local ok, follow = pcall(require, "harness-decorators.pi.follow")
  if ok then
    local s = follow.session_for_cwd(cwd)
    if s and (s.status == "working" or s.status == "idle") then
      return s.status
    end
  end
  -- No pushed state (pi run outside nvim): no per-pid signal, delegate to the child check.
  return "unknown"
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(_pid, cwd)
  if not cwd or cwd == "" then
    return nil
  end

  -- Preferred: the short uuid the extension pushed for this cwd (pi running in nvim).
  local ok, follow = pcall(require, "harness-decorators.pi.follow")
  if ok then
    local s = follow.session_for_cwd(cwd)
    if s and s.session_id then
      return follow.short_uuid(s.session_id)
    end
  end

  -- Fallback: derive the uuid from the session file whose mtime matches THIS terminal's open time
  -- (a fresh session in a dir with older ones must not inherit the previous one). term.opened_at is
  -- nil for non-term contexts/tests, which falls through to newest_jsonl.
  local dir = sessions_root() .. "/" .. dir_name(cwd)
  if not vim.uv.fs_stat(dir) then
    return nil
  end
  local f = nil
  local ok_term, term = pcall(require, "harness-decorators.term")
  if ok_term and type(term.opened_at) == "function" then
    f = jsonl_for_open(dir, term.opened_at("pi"))
  end
  if not f then
    f = newest_jsonl(dir)
  end
  if not f then
    return nil
  end
  local uuid = vim.fn.fnamemodify(f, ":t"):match("_([%x%-]+)%.jsonl$")
  if not uuid then
    return nil
  end
  return uuid:sub(1, 8)
end

return M
