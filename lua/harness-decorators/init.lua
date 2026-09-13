local M = {}

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")

---Callback for VimLeavePre autocmd.
local function on_vim_leave()
  watcher.stop()
end

---Start the JSONL watcher (and only it) if it isn't running yet. Called from the
---first <leader>c press, i.e. when claudecode.nvim creates the floating terminal
---buffer for the first time: no terminal means no session, so there is nothing to
---watch until then. Idempotent - watcher.start() returns early while a handle
---exists, and the VimLeavePre group's clear=true keeps this re-entrant safe.
function M.setup_auto_follow()
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
    -- No pin yet. A real harness (claude/copilot/maki) will pin once a session starts, so
    -- show the spinner as "waiting". A stub harness (crush/pi) has no sessions dir and can
    -- never pin - render empty instead of an eternal spinner.
    local ok_a, adapter = pcall(require, "harness-decorators." .. utils.harness)
    if ok_a and adapter and not adapter.projects_dir() then
      return ""
    end
    return "🤖 " .. frame
  end
  -- Harness-aware session id (copilot's is the parent dir, not the filename stem). A raw
  -- path:match("([^/]+)%.jsonl$") would show the wrong name for non-claude harnesses.
  local name = utils.extract_session_id(path)
  if not name then
    return ""
  end
  return "🤖 " .. name
end

return M
