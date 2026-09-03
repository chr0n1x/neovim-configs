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

  -- Reset state.
  utils.reset_dedup()
  utils.reset_log()
  watcher.pinned_jsonl_path = nil
  watcher.ignored_jsonl_paths = {}
  watcher.pin_notified = false

  watcher.start()
end

---Public accessor: always reads from the watcher module.
function M.get_pinned_path()
  return watcher.pinned_jsonl_path
end

return M
