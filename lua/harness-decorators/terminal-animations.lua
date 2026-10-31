-- Window animation for the harness floats and their minimized bars: an in_out_sine move to a target
-- rect at 60fps, 300ms unless NVIM_HARNESS_ANIMATION_MS says otherwise (0 jumps straight there). A
-- terminal float's size is applied in one step unless the caller asks for a smooth size. Without
-- animation.nvim it jumps straight to the target.

local DEFAULT_MS = 300

---The animation length in ms from NVIM_HARNESS_ANIMATION_MS, read on every call; anything that is
-- not a number of 0 or more gives the default.
---@return number
local function duration_ms()
  local ms = tonumber(os.getenv("NVIM_HARNESS_ANIMATION_MS") or "")
  if not ms or ms < 0 then
    return DEFAULT_MS
  end
  return ms
end

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
---@param smooth_size? boolean interpolate a terminal window's size every frame too
---@return boolean started false when win is not valid
local function animate_win(handle, key, win, to, base, on_done, smooth_size)
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
  local ms = duration_ms()
  local ok_anim, Animation = pcall(require, "animation")
  if ms == 0 or not ok_anim then
    set(final)
    if on_done then
      on_done()
    end
    return true
  end
  local cur = vim.api.nvim_win_get_config(win)
  local from = { row = cur.row or 0, col = cur.col or 0, width = cur.width, height = cur.height }
  -- Each size change of a terminal window resizes the terminal, and the harness redraws its whole
  -- screen on that SIGWINCH. So by default a terminal window animates only its position: per axis, a
  -- shrinking size applies on the first frame and a growing one on the last, and it never covers more
  -- than the larger of its two rects. Other windows (the minimized bars), and terminal windows with
  -- smooth_size (a single float going to or from fullscreen), resize smoothly.
  local stepped = not smooth_size and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal"
  local function size(f, a, b)
    if stepped then
      return math.min(a, b)
    end
    return math.floor(a + f * (b - a))
  end
  local finished = false
  handle[key] = Animation(ms, 60, require("animation.easing").in_out_sine, function(f)
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
      width = math.max(1, size(f, from.width, final.width)),
      height = math.max(1, size(f, from.height, final.height)),
    })
  end)
  handle[key]:run()
  return true
end

---Animate a harness float (a Snacks instance) to `target`.
---@param self table the Snacks terminal instance
---@param target { row: number, col: number, width: number, height: number }
---@param on_done? fun()
---@param smooth_size? boolean see animate_win
---@return boolean started
local function animate_resize(self, target, on_done, smooth_size)
  local base = { style = "minimal", border = self.opts.border or "rounded" }
  return animate_win(self, "_resize_anim", self.win, target, base, on_done, smooth_size)
end

return { animate_win = animate_win, animate_resize = animate_resize }
