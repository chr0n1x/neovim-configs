-- Generic agent state: work status + session label for each harness, ported
-- from the tmux picker (tmux-agent-pick.sh) so Neovim can broadcast statuses
-- (lualine etc.) without shelling out to ps/awk per pane.
--
-- Per-harness adapters live in harness-decorators.<name>.state and implement:
--   M.status(pid, cwd)  -> "working" | "idle" | "unknown"
--   M.label(pid, cwd)   -> string? (nil = no label; caller falls back to name)
-- Adapters may also set M.no_child_check = true when the child-process count is
-- misleading for that harness (copilot spawns helper subprocesses even at rest).
-- Returning "unknown" from status delegates to the shared child-process check.
--
-- Inputs are term-based: pid comes from the harness's live Snacks terminal
-- buffer, cwd from the current window. A harness with no open float simply has
-- no state entry - same as the tmux picker showing a dim dot for an empty pane.

local M = {}

---All harnesses that have a state adapter. The candidate list is the single source of truth in
--utils.list_harnesses() (discovers sibling dirs with env.lua + keymaps.lua); we keep only those that
--also ship a state.lua, so adding a new harness dir never requires editing this file.
---Each entry also carries an `installed` boolean: whether the harness CLI's first-token command is
--found on PATH (checked via utils.command_executable against the env module's return value).
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

---Child-process count for a pid from one ps snapshot (same portable check the
--tmux script uses: BSD ps has no --ppid, so count ppid matches in a snapshot).
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

---One ps snapshot per poll (not per harness), threaded into child_count.
---@return string
function M.ps_snapshot()
  local out = {}
  local h = io.popen("ps -eo pid=,ppid=")
  if h then
    for line in h:lines() do
      out[#out + 1] = line
    end
    h:close()
  end
  return table.concat(out, "\n")
end

---Status via the shared child-process check (the maki/aider/codex/... default
--in the tmux script). Tool/bash execution shows as working; pure text
--generation does not (in-process model backend, no per-pid signal).
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
--carries .pty and .argv, which is all we need to resolve the agent's pid.
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
---macOS (/dev/ttys006 -> ttys006) and Linux (/dev/pts/3 -> pts/3) report the pty without /dev/.
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
  local matches = {}
  for line in snap:gmatch("[^\n]+") do
    local pid, ppid, process_tty = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)")
    if pid and process_tty == tty then
      matches[pid] = ppid
    end
  end
  for pid, ppid in pairs(matches) do
    if not matches[ppid] then
      return tonumber(pid)
    end
  end
  return nil
end

---Resolve the agent's pid from a terminal buffer. macOS has no /proc, so use the terminal's
---tty from ps there. Linux keeps the rdev-based /proc path as a fallback.
---@param bufnr number
---@return number? pid
function M.pid_for_buf(bufnr)
  local chan = terminal_chan(bufnr)
  if not chan or type(chan.pty) ~= "string" then
    return nil
  end

  local ps = io.popen("ps -eo pid=,ppid=,tty=")
  if ps then
    local lines = {}
    for line in ps:lines() do
      lines[#lines + 1] = line
    end
    ps:close()
    local pid = M.pid_from_tty_snapshot(table.concat(lines, "\n"), chan.pty)
    if pid then
      return pid
    end
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

  -- pid -> ppid map for the descendant check.
  local ppid_of = {}
  local h = io.popen("ps -eo pid=,ppid=")
  if h then
    for line in h:lines() do
      local pid, ppid = line:match("^(%d+)%s+(%d+)")
      if pid then
        ppid_of[pid] = ppid
      end
    end
    h:close()
  end

  -- Collect every process whose controlling tty is this pty. /proc/*/stat
  -- field 7 (tty_nr) is a numeric major*16M+minor, comparable to st.rdev.
  local matches = {}
  local hp = io.popen("ls /proc 2>/dev/null | grep -E '^[0-9]+$'")
  if hp then
    for pid in hp:lines() do
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
    hp:close()
  end

  if #matches == 0 then
    return nil
  end
  if #matches == 1 then
    return tonumber(matches[1])
  end
  -- Topmost match: its parent does not share the pty. This is the direct command Neovim launched;
  -- returning a leaf would make child_count always zero while that command is doing work.
  local matched = {}
  for _, pid in ipairs(matches) do
    matched[pid] = true
  end
  for _, pid in ipairs(matches) do
    if not matched[ppid_of[pid]] then
      return tonumber(pid)
    end
  end
  return tonumber(matches[1])
end

---Poll one harness. Returns nil when the harness has no live terminal (no float
--opened yet, or its process exited).
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
  local status
  if state.no_child_check then
    status = state.status(pid, cwd)
  else
    -- Adapter first; fall back to the child check when it can't decide.
    status = state.status(pid, cwd)
    if status == "unknown" then
      status = M.child_status(snap or M.ps_snapshot(), pid)
    end
  end

  local label = nil
  if type(state.label) == "function" then
    local ok2, l = pcall(state.label, pid, cwd)
    if ok2 and type(l) == "string" and l ~= "" then
      label = l
    end
  end

  local session_id = nil
  if type(state.session_id) == "function" then
    local ok2, id = pcall(state.session_id, pid, cwd)
    if ok2 and type(id) == "string" and id ~= "" then
      session_id = id
    end
  end

  return { status = status, label = label, session_id = session_id, pid = pid }
end

---Poll every harness that has a live terminal. One ps snapshot for the whole
--round. Result keyed by harness name.
---@return table<string, {status: string, label: string?, pid: number}>
function M.all()
  local snap = M.ps_snapshot()
  local out = {}
  for _, h in ipairs(M.harnesses()) do
    local r = M.poll(h.name, snap)
    if r then
      out[h.name] = r
    end
  end
  return out
end

return M
