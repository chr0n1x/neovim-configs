-- Shared state adapter for Pi-style harnesses (pi, pig): work status + session label.
--
-- Each harness keeps its own sessions root (pi: ~/.pi/agent/sessions, pig: ~/.pig/agent/sessions)
-- and names the session dir after the cwd (--<cwd>-- with the leading slash stripped and /, \, :
-- turned into -). Session files are <timestamp>_<uuid>.jsonl.
--
-- Preferred source, when the harness has a push bridge (pi/follow.lua): the session events the
-- harness extension pushes while it runs inside nvim, giving the real session id + working/idle.
-- Fallback: macOS won't expose a process's env, so the exact session isn't reachable by pid; take
-- the session file whose mtime best matches the terminal's open time and derive the uuid from its
-- filename. Status has no fallback signal, so it stays "unknown" (delegates to the shared child
-- check).

local utils = require("harness-decorators.utils")

local M = {}

---cwd -> session dir name (ported from the sed in the tmux script).
---@param cwd string
---@return string
local function dir_name(cwd)
  local s = cwd:match("^/(.*)$") or cwd
  s = s:gsub("/", "-"):gsub("\\", "-"):gsub(":", "-")
  return "--" .. s .. "--"
end

---The *.jsonl in `dir` whose mtime best matches the terminal's open time. A fresh session started
--in a dir that already has older ones must NOT be labelled with the previous one, so we match by
--open time rather than "newest file". Returns nil when nothing is close enough.
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

---Most recently modified *.jsonl in a dir. Fallback when no session's mtime matches the
--terminal's open time.
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

---Turn state from the tail of a session file: "idle" when the last message entry is an assistant
--that stopped (stop/aborted/error), "working" for a trailing user/toolResult message or an
--assistant stopped on toolUse, nil when there is no message entry to read.
---@param path string
---@return "working"|"idle"|nil
local function turn_status(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local size = fh:seek("end")
  fh:seek("set", math.max(0, size - 65536))
  local tail = fh:read("*a") or ""
  fh:close()
  local last
  for line in tail:gmatch("[^\n]+") do
    local ok, e = pcall(vim.json.decode, line)
    if ok and type(e) == "table" and e.type == "message" and type(e.message) == "table" then
      last = e.message
    end
  end
  if not last then
    return nil
  end
  local stopped = { stop = true, aborted = true, error = true }
  if last.role == "system" or (last.role == "assistant" and stopped[last.stopReason]) then
    return "idle"
  end
  return "working"
end

---Build a state adapter for one Pi-style harness.
---@param opts {harness: string, config_dir: string, follow: string?, turn_status: boolean?}
---  harness: name passed to term.opened_at; config_dir: dir under $HOME (".pi");
---  follow: module name of the push bridge, or nil when the harness has none;
---  turn_status: read working/idle from the session file instead of the child check
---@return table state adapter with status(pid, cwd) and label(pid, cwd)
function M.new(opts)
  local S = {}
  S.no_child_check = opts.turn_status or nil

  local function sessions_root()
    return (os.getenv("HOME") or "") .. "/" .. opts.config_dir .. "/agent/sessions"
  end

  ---This terminal's session file for a cwd: the one matching its open time, else the newest.
  ---@param cwd string
  ---@return string?
  local function session_file(cwd)
    if not cwd or cwd == "" then
      return nil
    end
    -- term.opened_at is nil for non-term contexts/tests, which falls through to newest_jsonl.
    local dir = sessions_root() .. "/" .. dir_name(cwd)
    if not vim.uv.fs_stat(dir) then
      return nil
    end
    local f = nil
    local ok_term, term = pcall(require, "harness-decorators.term")
    if ok_term and type(term.opened_at) == "function" then
      f = jsonl_for_open(dir, term.opened_at(opts.harness))
    end
    return f or newest_jsonl(dir)
  end

  local function pushed(cwd)
    if not opts.follow then
      return nil, nil
    end
    local ok, follow = pcall(require, opts.follow)
    if not ok then
      return nil, nil
    end
    return follow.session_for_cwd(cwd), follow
  end

  ---@param _pid number|string
  ---@param cwd string
  ---@return "working"|"idle"|"unknown"
  function S.status(_pid, cwd)
    local s = pushed(cwd)
    if s and (s.status == "working" or s.status == "idle") then
      return s.status
    end
    if opts.turn_status then
      local f = session_file(cwd)
      return f and turn_status(f) or "unknown"
    end
    return "unknown"
  end

  ---@param _pid number|string
  ---@param cwd string
  ---@return string?
  function S.label(_pid, cwd)
    if not cwd or cwd == "" then
      return nil
    end

    local s, follow = pushed(cwd)
    if s and s.session_id then
      return follow.short_uuid(s.session_id)
    end

    local f = session_file(cwd)
    if not f then
      return nil
    end
    local uuid = vim.fn.fnamemodify(f, ":t"):match("_([%x%-]+)%.jsonl$")
    if not uuid then
      return nil
    end
    return uuid:sub(1, 8)
  end

  return S
end

return M
