local M = {}

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")
local keymaps = require("harness-decorators.keymaps")
local switch = require("harness-decorators.switch")
local title = require("harness-decorators.title")
local focus = require("harness-decorators.focus")

---Callback for VimLeavePre autocmd.
local function on_vim_leave()
  watcher.stop()
end

---Startup wiring: keymaps, switch state, WinLeave/ColorScheme autocmds, adapter on_activate.
---@param harness string the active harness name (NVIM_LLM_HARNESS or "claude")
function M.setup(harness)
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

  -- Optional per-adapter activation hook. Only pi defines on_activate (symlinks its
  -- edit-following extension into pi's extensions dir); guarded so every other harness
  -- and the stub base are unaffected.
  local ok_ad, adapter = pcall(require, "harness-decorators." .. harness)
  if ok_ad and type(adapter.on_activate) == "function" then
    pcall(adapter.on_activate)
  end
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

  watcher.start()
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
  if not path then
    local ok_c, display_c = pcall(require, "harness-decorators.agent-display")
    if ok_c and display_c.count() == 0 then
      return "0 agents"
    end
    local ok_a, adapter = pcall(require, "harness-decorators." .. utils.harness)
    if ok_a and adapter and not adapter.projects_dir() then
      local ok_d, display = pcall(require, "harness-decorators.agent-display")
      local state = ok_d and display.status(utils.harness) or nil
      local status = state and display.dot_for(state.status) or nil
      local identity = (state and state.session_id) or utils.harness
      local prefix = "%#lualine_x_normal#🤖%*"
      return prefix .. (status and " " .. status or "") .. " " .. identity
    end
    -- The robot emoji carries the section highlight (see plugins/lualine.lua), so it is the only part
    -- of this slot with the section fill. The spinner uses the working-dot blue.
    local ok_d, display = pcall(require, "harness-decorators.agent-display")
    local spin_hl = (ok_d and display.HL_WORKING) or ""
    return "%#lualine_x_normal#🤖%*" .. " %#" .. spin_hl .. "#" .. frame .. "%*"
  end
  -- Harness-aware session id (copilot's is the parent dir, not the filename stem).
  local name = utils.extract_session_id(path)
  if not name then
    return ""
  end
  -- Show working/idle status or the stale-idle ring; omit unknown status.
  local dot = ""
  local ok_d, display = pcall(require, "harness-decorators.agent-display")
  if ok_d then
    local state = display.status(utils.harness)
    if state and type(display.dot_for) == "function" then
      dot = display.dot_for(state.status) or ""
    end
  end
  -- Dot sits between the robot and the session id.
  local prefix = "%#lualine_x_normal#🤖%*" .. (dot ~= "" and " " .. dot or "") .. " "
  return prefix .. name
end

return M
