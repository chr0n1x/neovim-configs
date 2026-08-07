local M = {}

local utils = require("claude-decorators.utils")
local watcher = require("claude-decorators.inotify-watcher")
local edit_jump = require("claude-decorators.edit-jump")

---Callback for VimLeavePre autocmd.
local function on_vim_leave()
  watcher.stop()
  watcher.stop_legacy_poll()
end

M.setup_auto_follow = function()
  local group = vim.api.nvim_create_augroup("ClaudeAutoFollow", { clear = true })

  -- Path 1: diff accepted (review mode).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeCodeDiffClosed",
    callback = edit_jump.on_diff_closed,
  })

  -- Path 2: automode direct edits detected via inotifywait watcher.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeAutoFollowEdit",
    callback = edit_jump.on_edit,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = on_vim_leave,
  })

  -- Reset state.
  utils.reset_dedup()
  utils.reset_log()
  watcher.pinned_jsonl_path = nil

  watcher.start()
end

M.setup = function()
  local ok, err = pcall(M.setup_auto_follow)
  if not ok then
    utils.log("setup failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---Public accessor: always reads from the watcher module.
function M.get_pinned_path()
  return watcher.pinned_jsonl_path
end

return M
