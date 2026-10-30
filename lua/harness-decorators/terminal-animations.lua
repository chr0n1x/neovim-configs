-- Window animation for the harness floats and their minimized bars: a 300ms, 60fps in_out_sine move
-- and resize to a target rect. Without animation.nvim it jumps straight to the target.

---Animate `win` from where it is now to `to` ({ row, col, width, height }), landing exactly on `to`
-- and then calling on_done. The running animation is kept in handle[key]; one already running there
-- is stopped first, so the new one starts from wherever the window is now. on_done does not run when
-- a newer animation cuts this one off.
---@param handle table owner of the animation (e.g. the Snacks instance)
---@param key string field of handle that holds the running animation
---@param win integer?
---@param to { row: number, col: number, width: number, height: number }
---@param base? table window config merged into every frame
---@param on_done? fun()
---@return boolean started false when win is not valid
local function animate_win(handle, key, win, to, base, on_done)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if handle[key] then
    handle[key]:finish()
    handle[key] = nil
  end
  base = vim.tbl_extend("force", { relative = "editor" }, base or {})
  -- Frames run on a timer; by then the window may be gone or re-parented by a newer animation, so
  -- nvim_win_set_config can raise (E474). A missed cosmetic frame is harmless.
  local function set(rect)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_config, win, vim.tbl_extend("force", base, rect))
    end
  end
  local final = {
    row = math.floor(to.row),
    col = math.floor(to.col),
    width = math.floor(to.width),
    height = math.floor(to.height),
  }
  local ok_anim, Animation = pcall(require, "animation")
  if not ok_anim then
    set(final)
    if on_done then
      on_done()
    end
    return true
  end
  local cur = vim.api.nvim_win_get_config(win)
  local from = { row = cur.row or 0, col = cur.col or 0, width = cur.width, height = cur.height }
  local finished = false
  handle[key] = Animation(300, 60, require("animation.easing").in_out_sine, function(f)
    if not vim.api.nvim_win_is_valid(win) then
      return true
    end
    if f >= 1 then
      if not finished then
        finished = true
        set(final)
        if on_done then
          on_done()
        end
      end
      return
    end
    set({
      row = math.floor(from.row + f * (to.row - from.row)),
      col = math.floor(from.col + f * (to.col - from.col)),
      width = math.max(1, math.floor(from.width + f * (to.width - from.width))),
      height = math.max(1, math.floor(from.height + f * (to.height - from.height))),
    })
  end)
  handle[key]:run()
  return true
end

---Animate a harness float (a Snacks instance) to `target`.
---@param self table the Snacks terminal instance
---@param target { row: number, col: number, width: number, height: number }
---@param on_done? fun()
---@return boolean started
local function animate_resize(self, target, on_done)
  local base = { style = "minimal", border = self.opts.border or "rounded" }
  return animate_win(self, "_resize_anim", self.win, target, base, on_done)
end

return { animate_win = animate_win, animate_resize = animate_resize }
