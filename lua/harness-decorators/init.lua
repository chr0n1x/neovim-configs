local M = {}

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")

---Callback for VimLeavePre autocmd.
local function on_vim_leave()
  watcher.stop()
end

M.setup_auto_follow = function()
  local group = vim.api.nvim_create_augroup("ClaudeAutoFollow", { clear = true })

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

  if utils.harness == "maki" then
    -- Maki's floating terminal loses focus back to the code window after each
    -- edit, so the buffer-jump-on-edit feature is unreliable. Tell the user
    -- once per session instead of silently not jumping.
    vim.schedule(function()
      utils.log(
        "file auto-follow (buffer jump on agent edits) is not supported; notifications only",
        vim.log.levels.WARN
      )
    end)
  end
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
