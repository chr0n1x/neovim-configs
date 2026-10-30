-- Generic agent state: work status + session label for each harness, ported
-- from the tmux picker (tmux-agent-pick.sh) so Neovim can broadcast statuses
-- (lualine etc.) without shelling out to ps/awk per pane.
--
-- Per-harness adapters live in harness-decorators.<name>.state and implement:
--   M.status(pid, cwd) returns "working" | "idle" | "unknown"
--   M.label(pid, cwd) returns string? (nil = no label; caller falls back to name)
-- Optional inputs(pid, cwd) is shared by status, label and session_id as their third argument.
-- Its label_key and label_paths identify cached labels; close releases per-poll resources.
-- Adapters may also set M.no_child_check = true when the child-process count is
-- misleading for that harness (copilot spawns helper subprocesses even at rest).
-- Returning "unknown" from status delegates to the shared child-process check.
--
-- Inputs are term-based: pid comes from the harness's live Snacks terminal
-- buffer, cwd from term.cwd(name) (the spawn cwd), falling back to getcwd(). A
-- harness with no open float has no state entry.

local M = {}
local labels = {}

local function poll_label(name, state, pid, cwd, inputs)
  if type(state.label) ~= "function" then
    return nil
  end
  local key
  if inputs and inputs.label_key then
    key = { inputs.label_key }
    for _, path in ipairs(inputs.label_paths or {}) do
      local st = vim.uv.fs_stat(path)
      key[#key + 1] = { path, st and st.mtime or false }
    end
    local cached = labels[name]
    if cached and vim.deep_equal(cached.key, key) then
      return cached.label
    end
  end
  local ok, label = pcall(state.label, pid, cwd, inputs)
  if not ok then
    return nil
  end
  if type(label) ~= "string" or label == "" then
    label = nil
  end
  if key then
    labels[name] = { key = key, label = label }
  else
    labels[name] = nil
  end
  return label
end

---Harnesses with a state.lua, plus whether their CLI is on PATH.
---@return {name: string, installed: boolean}[]
function M.harnesses()
  local ok_u, u = pcall(require, "harness-decorators.utils")
  if not ok_u or type(u.list_harnesses) ~= "function" then
    return {}
  end
  local out = {}
  for _, name in ipairs(u.list_harnesses()) do
    local ok = pcall(require, "harness-decorators." .. name .. ".state")
    if ok then
      local installed = false
      local ok_env, cmd = pcall(require, "harness-decorators." .. name .. ".env")
      if ok_env and type(cmd) == "string" then
        installed = u.command_executable(cmd)
      end
      out[#out + 1] = { name = name, installed = installed }
    end
  end
  return out
end

---Child-process count for a pid from one ps snapshot (BSD ps has no --ppid, so
---count ppid matches in the snapshot).
---@param snap string? Precomputed "pid ppid" lines (shared across panes)
---@param pid number|string
---@return integer
function M.child_count(snap, pid)
  if not snap or not pid then
    return 0
  end
  local n = 0
  for line in snap:gmatch("[^\n]+") do
    local p, parent = line:match("^(%d+)%s+(%d+)")
    if p and parent == tostring(pid) then
      n = n + 1
    end
  end
  return n
end

---Output lines of a shell command; empty when it cannot be started.
---@param cmd string
---@return string[]
local function popen_lines(cmd)
  local out = {}
  local h = io.popen(cmd)
  if h then
    for line in h:lines() do
      out[#out + 1] = line
    end
    h:close()
  end
  return out
end

---The first pid in `pids` whose parent is not in `pids`: among processes sharing a pty, the
---command Neovim launched.
---@param pids string[]
---@param ppid_of table<string, string>
---@return number?
local function topmost(pids, ppid_of)
  local set = {}
  for _, pid in ipairs(pids) do
    set[pid] = true
  end
  for _, pid in ipairs(pids) do
    if not set[ppid_of[pid]] then
      return tonumber(pid)
    end
  end
  return nil
end

---One ps snapshot per poll (not per harness), threaded into child_count.
---@return string
function M.ps_snapshot()
  return table.concat(popen_lines("ps -eo pid=,ppid="), "\n")
end

---Status via the shared child-process check. Tool/bash execution shows as
---working; pure text generation does not (in-process model backend, no per-pid signal).
---@param snap string?
---@param pid number|string
---@return "working"|"idle"
function M.child_status(snap, pid)
  if M.child_count(snap, pid) > 0 then
    return "working"
  end
  return "idle"
end

---The terminal channel for a buffer (mode == "terminal"), or nil. The chan
---carries .pty and .argv, which is all we need to resolve the agent's pid.
---@param bufnr number
---@return table? chan
local function terminal_chan(bufnr)
  local ok, chans = pcall(vim.api.nvim_list_chans)
  if not ok or type(chans) ~= "table" then
    return nil
  end
  for _, ch in ipairs(chans) do
    if type(ch) == "table" and ch.mode == "terminal" and (ch.buf == bufnr or ch.buffer == bufnr) then
      return ch
    end
  end
  return nil
end

---Resolve the direct process launched for a terminal pty from a portable ps snapshot. Both
---macOS (/dev/ttys006 as ttys006) and Linux (/dev/pts/3 as pts/3) report the pty without /dev/.
---When descendants share the pty, return the topmost one because that is the command Neovim
---launched; child-process status detection depends on counting its descendants.
---@param snap string? Precomputed "pid ppid tty" lines
---@param pty string Terminal pty path
---@return number? pid
function M.pid_from_tty_snapshot(snap, pty)
  if not snap or type(pty) ~= "string" then
    return nil
  end
  local tty = pty:gsub("^/dev/", "")
  local matches, ppid_of = {}, {}
  for line in snap:gmatch("[^\n]+") do
    local pid, ppid, process_tty = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)")
    if pid and process_tty == tty then
      matches[#matches + 1] = pid
      ppid_of[pid] = ppid
    end
  end
  return topmost(matches, ppid_of)
end

---Resolve the agent's pid from a terminal buffer: the terminal job's pid, which is the command
---Neovim launched. When that lookup fails, fall back to matching the terminal's tty in ps, then
---to the rdev-based /proc scan (Linux only).
---@param bufnr number
---@return number? pid
function M.pid_for_buf(bufnr)
  local chan = terminal_chan(bufnr)
  if not chan then
    return nil
  end
  local ok_job, job_pid = pcall(vim.fn.jobpid, chan.id)
  if ok_job and type(job_pid) == "number" and job_pid > 0 then
    return job_pid
  end
  if type(chan.pty) ~= "string" then
    return nil
  end

  local tty_pid = M.pid_from_tty_snapshot(table.concat(popen_lines("ps -eo pid=,ppid=,tty="), "\n"), chan.pty)
  if tty_pid then
    return tty_pid
  end

  local ok_fd, fd = pcall(vim.uv.fs_open, chan.pty, "r", 438) -- O_RDONLY
  if not ok_fd or type(fd) ~= "number" then
    return nil
  end
  local ok_st, st = pcall(vim.uv.fs_fstat, fd)
  vim.uv.fs_close(fd)
  if not ok_st or type(st) ~= "table" or type(st.rdev) ~= "number" then
    return nil
  end
  local target_rdev = st.rdev

  -- pid to ppid map for the descendant check.
  local ppid_of = {}
  for _, line in ipairs(popen_lines("ps -eo pid=,ppid=")) do
    local pid, ppid = line:match("^(%d+)%s+(%d+)")
    if pid then
      ppid_of[pid] = ppid
    end
  end

  -- Collect every process whose controlling tty is this pty. /proc/*/stat
  -- field 7 (tty_nr) is a numeric major*16M+minor, comparable to st.rdev.
  local matches = {}
  for _, pid in ipairs(popen_lines("ls /proc 2>/dev/null | grep -E '^[0-9]+$'")) do
    local f = io.open("/proc/" .. pid .. "/stat", "r")
    if f then
      local data = f:read("*a")
      f:close()
      -- comm may contain spaces/parens, so anchor past the closing ")".
      local rest = data:match("^%d+ %b()%s+%w%s+(.*)$")
      if rest then
        local fields = {}
        for word in rest:gmatch("%S+") do
          fields[#fields + 1] = word
        end
        -- rest starts at state (field 3); tty_nr is field 7 = index 4.
        if tonumber(fields[4]) == target_rdev then
          matches[#matches + 1] = pid
        end
      end
    end
  end

  if #matches == 0 then
    return nil
  end
  if #matches == 1 then
    return tonumber(matches[1])
  end
  -- A leaf would make child_count always zero while the launched command is doing work.
  return topmost(matches, ppid_of) or tonumber(matches[1])
end

---Poll one harness. Returns nil when the harness has no live terminal (no float
---opened yet, or its process exited).
---@param name string Harness name (claude|maki|copilot|crush|pi)
---@param snap? string Shared ps snapshot for this poll round
---@return {status: string, label: string?, pid: number}|nil
function M.poll(name, snap)
  local ok, state = pcall(require, "harness-decorators." .. name .. ".state")
  if not ok or type(state) ~= "table" then
    return nil
  end

  -- Term-based inputs: the harness's live Snacks terminal buffer.
  local term_ok, term = pcall(require, "harness-decorators.term")
  if not term_ok or type(term.bufnr) ~= "function" then
    return nil
  end
  local bufnr = term.bufnr(name)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local pid = M.pid_for_buf(bufnr)
  if not pid then
    return nil
  end

  local cwd = type(term.cwd) == "function" and term.cwd(name) or nil
  cwd = cwd or vim.fn.getcwd()
  local inputs = type(state.inputs) == "function" and state.inputs(pid, cwd) or nil
  local ok_status, status = pcall(state.status, pid, cwd, inputs)
  if not ok_status then
    if inputs and type(inputs.close) == "function" then
      inputs.close()
    end
    error(status)
  end
  if not state.no_child_check and status == "unknown" then
    status = M.child_status(snap or M.ps_snapshot(), pid)
  end

  local label = poll_label(name, state, pid, cwd, inputs)
  local session_id = nil
  if type(state.session_id) == "function" then
    local ok2, id = pcall(state.session_id, pid, cwd, inputs)
    if ok2 and type(id) == "string" and id ~= "" then
      session_id = id
    end
  end
  if inputs and type(inputs.close) == "function" then
    inputs.close()
  end

  return { status = status, label = label, session_id = session_id, pid = pid }
end

---Poll every harness that has a live terminal. One ps snapshot for the whole
---round. Result keyed by harness name.
---@param snap? string ps snapshot to use instead of taking one
---@return table<string, {status: string, label: string?, pid: number}>
function M.all(snap)
  snap = snap or M.ps_snapshot()
  local out = {}
  for _, h in ipairs(M.harnesses()) do
    local r = M.poll(h.name, snap)
    if r then
      out[h.name] = r
    end
  end
  return out
end

---M.all with the ps snapshot taken off the main loop, so the poll never blocks typing. The
---callback runs on the main loop with the same result M.all returns.
---@param cb fun(all: table<string, {status: string, label: string?, pid: number}>)
function M.all_async(cb)
  local ok = pcall(vim.system, { "ps", "-eo", "pid=,ppid=" }, { text = true }, function(res)
    vim.schedule(function()
      cb(M.all(res.code == 0 and res.stdout or ""))
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(M.all(""))
    end)
  end
end

return M
