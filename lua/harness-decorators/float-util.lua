-- Small window helpers shared by the harness float (term.lua) and its minimized bar (dock.lua).
local M = {}

---Whether this is another window with no z-index and an existing buffer path.
local function valid_buf(win_id)
  local config = vim.api.nvim_win_get_config(win_id)
  local buf_info = vim.api.nvim_win_get_buf(win_id)
  local buf_name = vim.api.nvim_buf_get_name(buf_info)
  local terminal_win = vim.api.nvim_get_current_win()

  return not config.z and win_id ~= terminal_win and vim.uv.fs_stat(buf_name) ~= nil
end

---Focus the first eligible window in reverse tab-window order.
function M.find_base_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)

  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    if valid_buf(win_id) then
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end
end

---The harness title with a grip glyph prepended, marking the top border as the move handle.
---@param harness string
---@return table chunks
function M.grip_title(harness)
  local t = require("harness-decorators.title").title(harness)
  return vim.list_extend({ { " ✥", "Special" } }, type(t) == "string" and { { t, "FloatTitle" } } or t)
end

return M
