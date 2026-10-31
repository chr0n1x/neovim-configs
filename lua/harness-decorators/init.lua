local M = {}

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")
local keymaps = require("harness-decorators.keymaps")
local switch = require("harness-decorators.switch")
local title = require("harness-decorators.title")
local focus = require("harness-decorators.focus")

---Collect the pid of every live harness process from state.table.
---@return number[] pids
local function harness_pids()
  local pids = {}
  local state = require("harness-decorators.state")
  for _, e in pairs(state.table) do
    local inst = e.inst
    if inst and inst.buf and vim.api.nvim_buf_is_valid(inst.buf) then
      local chan = vim.bo[inst.buf].channel
      if chan and chan > 0 then
        local ok_pid, pid = pcall(vim.fn.jobpid, chan)
        if ok_pid and pid and pid > 0 then
          table.insert(pids, pid)
        end
      end
    end
  end
  return pids
end

---SIGTERM every live harness process and wait (bounded) until all are actually
---dead. A SIGTERM that is not acknowledged leaves the harness writing to its
---session JSONL after we have "stopped", so the wait is part of the contract,
---not an optimization.
local function stop_harnesses()
  local pids = harness_pids()
  for _, pid in ipairs(pids) do
    pcall(vim.uv.kill, pid, "sigterm")
  end
  -- Probe with signal 0: uv.kill(pid, 0) returns 0 while the process is alive,
  -- nil once it is gone. Bounded so a harness that ignores SIGTERM cannot hold
  -- :qa! hostage; on timeout we proceed and let the OS finish it.
  local deadline = vim.uv.hrtime() + 5 * 1000000000 -- 5s
  while vim.uv.hrtime() < deadline do
    local all_dead = true
    for _, pid in ipairs(pids) do
      local ok, ret = pcall(vim.uv.kill, pid, 0)
      if ok and ret == 0 then
        all_dead = false
        break
      end
    end
    if all_dead then
      break
    end
    vim.wait(50, function()
      return false
    end)
  end
end

---Stop the inotify watcher and wait (bounded) until its log and pidfile are
---actually gone from disk. watcher.stop() SIGTERMs the process and waits for
---the exit callback, but the file deletion happens in that callback - which may
---not have run by the time stop() returns.
local function stop_watcher_and_verify()
  watcher.stop()
  local log, pidfile = watcher.watcher_log, watcher.watcher_pidfile
  local function files_gone()
    if not log and not pidfile then
      return true
    end
    local log_gone = (not log) or (io.open(log, "r") == nil)
    local pidfile_gone = (not pidfile) or (io.open(pidfile, "r") == nil)
    return log_gone and pidfile_gone
  end
  if not files_gone() then
    local deadline = vim.uv.hrtime() + 5 * 1000000000 -- 5s
    while vim.uv.hrtime() < deadline and not files_gone() do
      vim.wait(50, function()
        return false
      end)
    end
  end
end

---Stop the inotify watcher and SIGTERM all running harness processes.
---Idempotent: safe to call from both the VimLeavePre autocmd and M.shutdown().
local function cleanup()
  stop_harnesses()
  stop_watcher_and_verify()
end

---VimLeavePre autocmd callback.
local function on_vim_leave()
  cleanup()
end

---Startup wiring: keymaps, switch state, WinLeave/ColorScheme autocmds, adapter on_activate.
---@param harness string the active harness name (NVIM_LLM_HARNESS or "claude")
function M.setup(harness)
  local adapter = require("harness-decorators." .. harness)
  keymaps.apply(keymaps.build(harness))
  switch.init(harness)

  vim.api.nvim_create_autocmd("WinLeave", {
    pattern = "*",
    callback = focus.capture,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    callback = function()
      title.define_all()
      pcall(require("harness-decorators.agent-display").setup_highlights)
    end,
  })

  switch.activate_adapter(harness, adapter)
end

---True once the jump autocmds and VimLeavePre handler have been registered for this nvim
---session. Guards setup_auto_follow so a second <leader>c press (e.g. after closing and
---reopening the terminal) does not re-register the autocmds or re-run the startup resets.
local initialized = false

---Register jump/leave autocmds and start the watcher once per nvim session.
function M.setup_auto_follow()
  if initialized then
    return
  end
  initialized = true

  local group = vim.api.nvim_create_augroup("HarnessAutoFollow", { clear = true })

  edit_jump.create_jump_autocmds(group)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = on_vim_leave,
  })

  -- Fresh dedup/log/pin state; byte offsets are kept.
  utils.reset_dedup()
  utils.reset_log()
  watcher.reset_pin_state()

  -- A harness whose process exited before this first follow stays unfollowed (term.follow_paused).
  local term = package.loaded["harness-decorators.term"]
  if term and term.follow_paused(require("harness-decorators.active").get()) then
    return
  end
  watcher.start()
end

---Run all shutdown cleanup (harness SIGTERM, watcher stop), then force-quit.
---Used by <leader>qq since :qa! can race with the VimLeavePre autocmd.
---_quit_cmd is the injectable exit hook: the real :qa! by default, swapped by
---tests so they can assert post-conditions without the process exiting.
M._quit_cmd = function()
  vim.cmd("qa!")
end

function M.shutdown()
  cleanup()
  M._quit_cmd()
end

---Public accessor: always reads from the watcher module.
function M.get_pinned_path()
  return watcher.pinned_jsonl_path
end

---Display string for the lualine session slot: "0 agents" when no agent is live; robot, status dot
---and session id for a harness with no sessions dir; a spinner while waiting for a pin; robot, dot
---and session id once pinned.
---@param frame string The current spinner frame to show while waiting for a pin.
---@return string
function M.session_component(frame)
  local path = M.get_pinned_path()
  local display = require("harness-decorators.agent-display")
  local harness = require("harness-decorators.active").get()
  if not path then
    if display.count() == 0 then
      return "0 agents"
    end
    local adapter = require("harness-decorators." .. harness)
    if not adapter.projects_dir() then
      local state = display.status(harness)
      local status = state and display.dot_for(state.status) or nil
      local identity = (state and state.session_id) or harness
      local prefix = "%#lualine_x_normal#🤖%*"
      return prefix .. (status and " " .. status or "") .. " " .. identity
    end
    -- The robot emoji carries the section highlight (see plugins/lualine.lua), so it is the only part
    -- of this slot with the section fill. The spinner uses the working-dot blue.
    local spin_hl = display.HL_WORKING
    return "%#lualine_x_normal#🤖%*" .. " %#" .. spin_hl .. "#" .. frame .. "%*"
  end
  -- Harness-aware session id (copilot's is the parent dir, not the filename stem).
  local name = utils.extract_session_id(path)
  if not name then
    return ""
  end
  -- Show working/idle status or the stale-idle ring; omit unknown status.
  local dot = ""
  local state = display.status(harness)
  if state and type(display.dot_for) == "function" then
    dot = display.dot_for(state.status) or ""
  end
  -- Dot sits between the robot and the session id.
  local prefix = "%#lualine_x_normal#🤖%*" .. (dot ~= "" and " " .. dot or "") .. " "
  return prefix .. name
end

return M
