-- Small window helpers shared by the harness float (term.lua) and its minimized bar (dock.lua).
local M = {}

---Whether win_id is a window other than the current one that shows a file on disk (floats
---included).
local function valid_buf(win_id)
  local buf_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win_id))
  return win_id ~= vim.api.nvim_get_current_win() and vim.uv.fs_stat(buf_name) ~= nil
end

---Focus the first eligible window in reverse tab-window order. Hidden windows stay eligible.
function M.find_base_window()
  local win = require("harness-decorators.windows").find(valid_buf, { reverse = true })
  if win then
    vim.api.nvim_set_current_win(win)
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
