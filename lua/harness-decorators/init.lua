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

---Startup wiring for the AI harness, called once from lua/plugins/ai-harness.lua (a lazy.nvim
--spec file that loads at startup). Registers the consolidated <leader>c* keymaps for the active
--harness, seeds switch.lua's initial state, and installs the two session-lifetime autocmds:
--WinLeave (remember the last normal-mode buffer so focus-gaining actions can restore it) and
--ColorScheme (re-define title/agent-overview highlight groups after a theme switch). The terminal
--itself is NOT opened here; the first <leader>c press opens it (and starts the JSONL watcher via
--setup_auto_follow). Kept in this module rather than ai-harness.lua so it has no plugin-spec
--dependency and tests can drive it directly.
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
end

---True once the jump autocmds and VimLeavePre handler have been registered for this nvim
---session. Guards setup_auto_follow so a second <leader>c press (e.g. after closing and
---reopening the terminal) does not re-register the autocmds or re-run the startup resets.
local initialized = false

---Register the jump/leave autocmds exactly once per nvim session. Called from the first
---<leader>c press, i.e. when claudecode.nvim creates the floating terminal buffer for the
---first time: no terminal means no session, so there is nothing to watch until then. The
---`initialized` flag makes a later call (close + reopen the terminal in the same session) a
---no-op, so dedup/pin state established by the first session is NOT wiped - previously every
---first-<leader>c press re-ran the resets below and re-pinned, causing duplicate
---notifications/jumps. See tests/init_spec.lua.
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

  -- Reset state. The pin-state trio goes through watcher's single definition so a field
  -- added there is covered here too; jsonl_positions and pending_notifications are
  -- deliberately NOT cleared at startup (a re-pin keeps byte offsets to avoid a missed
  -- write-batch). dedup + log caches are cleared fresh each startup.
  utils.reset_dedup()
  utils.reset_log()
  watcher.reset_pin_state()

  watcher.start()
end

---Public accessor: always reads from the watcher module.
function M.get_pinned_path()
  return watcher.pinned_jsonl_path
end

---Display string for the lualine harness/session slot: a spinner frame when no session is
---pinned yet (a real harness will pin once one starts), the pinned session's harness-aware id
---when pinned, or an empty string for a stub harness that has no sessions dir and can never
---pin (spinning forever there is just noise). Kept here rather than in plugins/lualine.lua so
---it is a plain module function that tests/lualine_spec.lua can drive without a live statusline.
---@param frame string The current spinner frame to show while waiting for a pin.
---@return string
function M.session_component(frame)
  local path = M.get_pinned_path()
  if not path then
    local ok_a, adapter = pcall(require, "harness-decorators." .. utils.harness)
    if ok_a and adapter and not adapter.projects_dir() then
      local ok_d, display = pcall(require, "harness-decorators.agent-display")
      local state = ok_d and display.status(utils.harness) or nil
      local status = state and display.dot_for(state.status) or nil
      local identity = (state and state.session_id) or utils.harness
      local prefix = "%#lualine_x_normal#🤖%*"
      return prefix .. (status and " " .. status or "") .. " " .. identity
    end
    -- The robot emoji carries the SECTION's highlight group (see plugins/lualine.lua), so it is the
    -- only part of this slot that shows the section fill. The waiting spinner uses the same blue as
    -- the working-state dot (AgentDotWorking) so "waiting" and "working" read as one color family;
    -- everything else reverts to the statusline default background.
    local ok_d, display = pcall(require, "harness-decorators.agent-display")
    local spin_hl = (ok_d and display.HL_WORKING) or ""
    return "%#lualine_x_normal#🤖%*" .. " %#" .. spin_hl .. "#" .. frame .. "%*"
  end
  -- Harness-aware session id (copilot's is the parent dir, not the filename stem). A raw
  -- path:match("([^/]+)%.jsonl$") would show the wrong name for non-claude harnesses.
  local name = utils.extract_session_id(path)
  if not name then
    return ""
  end
  -- The active agent's OWN status dot, next to its session id. Only shown when we actually KNOW its
  -- state (working/idle) - an unknown state renders nothing rather than a hollow ring of noise for
  -- the agent you're actively looking at. Polls just this harness (no live terminal -> nil).
  local dot = ""
  local ok_d, display = pcall(require, "harness-decorators.agent-display")
  if ok_d then
    local state = display.status(utils.harness)
    if state and type(display.dot_for) == "function" then
      dot = display.dot_for(state.status) or ""
    end
  end
  -- The dot sits right after the robot emoji (before the session id), not at the end. The emoji
  -- carries the SECTION's highlight group (see plugins/lualine.lua) so it is the only part of this
  -- slot that shows the section fill; everything after it reverts to the statusline default, keeping
  -- the dot and session id on the normal background.
  local prefix = "%#lualine_x_normal#🤖%*" .. (dot ~= "" and " " .. dot or "") .. " "
  return prefix .. name
end

return M
