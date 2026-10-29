local M = {}

---The zen-mode window and the window zen was opened from, while zen is open and its window is valid.
---@return integer? win
---@return integer? parent
function M.win()
  local ok, view = pcall(require, "zen-mode.view")
  if ok and view.is_open and view.is_open() and view.win and vim.api.nvim_win_is_valid(view.win) then
    return view.win, view.parent
  end
end

return M
