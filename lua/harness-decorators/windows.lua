local M = {}

---Find the first accepted window in the current tab. Callers own buffer and float eligibility;
---visible filters hidden windows, treating a failed config lookup as potentially visible.
---@param matches fun(win: integer): boolean
---@param opts? {reverse?: boolean, visible?: boolean}
---@return integer? win
function M.find(matches, opts)
  opts = opts or {}
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local first, last, step = 1, #wins, 1
  if opts.reverse then
    first, last, step = #wins, 1, -1
  end
  for ix = first, last, step do
    local win = wins[ix]
    local hidden = false
    if opts.visible then
      local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
      hidden = ok and cfg and cfg.hide or false
    end
    if not hidden and matches(win) then
      return win
    end
  end
end

return M
