-- Shared animation helper: smoothly transition the float window to `target`.
-- `target` is { row, col, width, height }.
-- `snap_config` (optional) is applied verbatim on the final frame to eliminate rounding residue.
local function animate_resize(self, target, snap_config)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if self._resize_anim and self._resize_anim:is_running() then
    self._resize_anim:finish()
  end

  local cur = vim.api.nvim_win_get_config(win)
  local sr, sc, sw, sh = cur.row or 0, cur.col or 0, cur.width or vim.o.columns, cur.height or vim.o.lines
  local border = self.opts.border or "rounded"

  local Animation = require("animation")
  local snapped = false
  self._resize_anim = Animation(300, 60, require("animation.easing").in_out_sine, function(f)
    if not vim.api.nvim_win_is_valid(win) then
      return true
    end
    if f == 1 and not snapped then
      snapped = true
      vim.api.nvim_win_set_config(win, snap_config or {
        relative = "editor",
        row = math.floor(target.row),
        col = math.floor(target.col),
        width = math.floor(target.width),
        height = math.floor(target.height),
        style = "minimal",
        border = border,
      })
      return
    end
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      style = "minimal",
      border = border,
      row = math.floor(sr + f * (target.row - sr)),
      col = math.floor(sc + f * (target.col - sc)),
      width = math.floor(sw + f * (target.width - sw)),
      height = math.floor(sh + f * (target.height - sh)),
    })
  end)
  self._resize_anim:run()
  return true
end

return { animate_resize = animate_resize }
