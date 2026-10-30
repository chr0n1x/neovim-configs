-- Mouse handling for the harness floats and their minimized bars: hit tests, border drags, and the
-- global expr mappings that feed them. term.lua calls setup on its first open.
local M = {}

local state = require("harness-decorators.state")
local layout = require("harness-decorators.layout")
local dock = require("harness-decorators.dock")
local BAR_HEIGHT, drawn_pos = layout.BAR_HEIGHT, layout.drawn_pos
local repack_dock, minimize_float, bar_hit, bar_button =
  dock.repack_dock, dock.minimize_float, dock.bar_hit, dock.bar_button

-- term.lua's float actions the handlers call: { is_live, restore_from_bar, close_harness,
-- shelf_button }. Passed in by setup, since term requires this module.
local handlers = {}

-- Mouse drag on a harness float's border: the top border (the title bar) moves the float, and the
-- left, right and bottom borders resize it from that edge (bottom corners resize both ways). The
-- mappings are global expr maps because the click can come from any window/mode; anything that is
-- not a border drag is passed through unchanged. Requires 'mouse' to include n/t (see <leader>M).
local drag = nil
local MIN_WIDTH, MIN_HEIGHT = 20, 5

---The live harness instance whose border contains the given 1-based screen pos, and which edges
-- of it were grabbed.
--
-- A grab on the bottom-right corner returns:
-- ```lua
-- inst, { move = false, left = false, right = true, bottom = true }
-- ```
--
-- Clicks inside the float's text area return nil.
---@return table? inst
---@return table? edges
local function border_hit(screenrow, screencol)
  for _, e in pairs(state.table) do
    local inst = e.inst
    if handlers.is_live(inst) and inst.win and vim.api.nvim_win_is_valid(inst.win) then
      local cfg = vim.api.nvim_win_get_config(inst.win)
      if cfg.relative == "editor" then
        local top, left = drawn_pos(inst.win)
        top, left = top + 1, left + 1
        local bottom, right = top + cfg.height + 1, left + cfg.width + 1
        if screenrow >= top and screenrow <= bottom and screencol >= left and screencol <= right then
          local edges = {
            move = screenrow == top,
            left = screenrow ~= top and screencol == left,
            right = screenrow ~= top and screencol == right,
            bottom = screenrow == bottom,
          }
          if edges.move or edges.left or edges.right or edges.bottom then
            return inst, edges
          end
        end
      end
    end
  end
end

---Apply the in-progress drag to the float: move it, or resize it from the grabbed edges, clamped to
-- the editor. The new geometry is also written to inst.opts so Snacks keeps it across hide/show and
-- VimResized, and the fullscreen baseline is dropped so the next <C-f> collapse returns here instead
-- of the pre-drag geometry. Dragging a minimized bar moves the bar, and the float reopens there.
local function drag_to(mouse)
  if not drag then
    return
  end
  local inst = drag.inst
  local dr, dc = mouse.screenrow - drag.screenrow, mouse.screencol - drag.screencol
  if drag.pill_win and vim.api.nvim_win_is_valid(drag.pill_win) then
    if inst._bar_slot then
      inst._bar_slot = nil
      repack_dock()
    end
    local row = math.max(0, math.min(drag.row + dr, vim.o.lines - vim.o.cmdheight - BAR_HEIGHT))
    local col = math.max(0, math.min(drag.col + dc, vim.o.columns - drag.width))
    pcall(vim.api.nvim_win_set_config, drag.pill_win, { relative = "editor", row = row, col = col })
    local rect = inst._restore_rect or { width = 0, height = 0 }
    inst.opts.row = math.max(0, math.min(row, vim.o.lines - vim.o.cmdheight - rect.height - 2))
    inst.opts.col = math.max(0, math.min(col, vim.o.columns - rect.width - 2))
    rect.row, rect.col = inst.opts.row, inst.opts.col
    return
  end
  if not (inst and inst.win and vim.api.nvim_win_is_valid(inst.win)) then
    drag = nil
    return
  end
  local row, col, width, height = drag.row, drag.col, drag.width, drag.height
  local edges = drag.edges
  if edges.move then
    row = math.max(0, math.min(row + dr, vim.o.lines - vim.o.cmdheight - height - 2))
    col = math.max(0, math.min(col + dc, vim.o.columns - width - 2))
  end
  if edges.bottom then
    height = math.max(MIN_HEIGHT, math.min(height + dr, vim.o.lines - vim.o.cmdheight - row - 2))
  end
  if edges.right then
    width = math.max(MIN_WIDTH, math.min(width + dc, vim.o.columns - col - 2))
  end
  if edges.left then
    col = math.max(0, math.min(col + dc, drag.col + drag.width - MIN_WIDTH))
    width = drag.width + drag.col - col
  end
  inst._resized_at = vim.uv.now()
  pcall(vim.api.nvim_win_set_config, inst.win, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
  })
  inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = row, col, width, height
  layout.set(inst, "normal", { forget_baseline = not drag.wide })
end

---Mouse handlers for the harness floats and their minimized bars. Each takes a getmousepos()-shaped
-- position and returns the keys the mapping should produce: "" when the event was handled here, or
-- the original mouse key to pass it through. The mappings below call these with vim.fn.getmousepos();
-- specs call them directly with made-up positions, since headless Neovim gets no real mouse input.

-- True from a press these handlers consumed until its release. The drag and release events of that
-- click are swallowed too: passed through, Neovim would move the cursor to the window under the
-- mouse, which after a restore or close is the editor window the bar was floating over.
local press_consumed = false

---@param mouse { screenrow: integer, screencol: integer }
---@return string keys
function M.press(mouse)
  press_consumed = true
  local minimized, bar = bar_hit(mouse.screenrow, mouse.screencol)
  local button = minimized and bar_button(minimized, bar, mouse.screencol)
  if button then
    drag = nil
    vim.schedule(function()
      if button == "close" then
        handlers.close_harness(minimized)
      else
        handlers.restore_from_bar(minimized)
      end
    end)
    return ""
  end
  if minimized then
    if minimized._bar_anim then
      minimized._bar_anim:finish()
      minimized._bar_anim = nil
    end
    local row, col = drawn_pos(bar)
    drag = {
      inst = minimized,
      pill_win = bar,
      screenrow = mouse.screenrow,
      screencol = mouse.screencol,
      row = row,
      col = col,
      width = vim.api.nvim_win_get_width(bar) + 2,
    }
    return ""
  end
  local inst, edges = border_hit(mouse.screenrow, mouse.screencol)
  if not inst then
    drag = nil
    press_consumed = false
    return "<LeftMouse>"
  end
  local cfg = vim.api.nvim_win_get_config(inst.win)
  local row, col = drawn_pos(inst.win)
  drag = {
    inst = inst,
    edges = edges,
    wide = layout.get(inst) == "fullscreen",
    screenrow = mouse.screenrow,
    screencol = mouse.screencol,
    row = row,
    col = col,
    width = cfg.width,
    height = cfg.height,
  }
  return ""
end

---@param mouse { screenrow: integer, screencol: integer }
---@return string keys
function M.drag(mouse)
  if not drag then
    return press_consumed and "" or "<LeftDrag>"
  end
  vim.schedule(function()
    drag_to(mouse)
  end)
  return ""
end

---@return string keys
function M.release()
  local consumed = press_consumed or drag ~= nil
  press_consumed = false
  drag = nil
  return consumed and "" or "<LeftRelease>"
end

---@param mouse { screenrow: integer, screencol: integer }
---@return string keys
function M.double(mouse)
  local minimized, bar = bar_hit(mouse.screenrow, mouse.screencol)
  if minimized then
    press_consumed = true
    -- The buttons already fired on the first click of the double-click.
    if not bar_button(minimized, bar, mouse.screencol) then
      vim.schedule(function()
        handlers.restore_from_bar(minimized)
      end)
    end
    return ""
  end
  local inst, edges = border_hit(mouse.screenrow, mouse.screencol)
  if inst and edges.move then
    local _, col = drawn_pos(inst.win)
    local on_minimize = mouse.screencol == col + vim.api.nvim_win_get_config(inst.win).width + 2
    local on_shelf = mouse.screencol == col + 1
    if on_minimize or on_shelf then
      drag = nil
      press_consumed = true
      vim.schedule(function()
        if on_minimize then
          minimize_float(inst)
        else
          handlers.shelf_button(inst)
        end
      end)
      return ""
    end
  end
  return "<2-LeftMouse>"
end

---Hand the module term.lua's float actions. Called when term loads, so the handlers work before any
-- mapping exists (specs call them directly).
---@param h table { is_live, restore_from_bar, close_harness, shelf_button }, each taking the instance
function M.bind(h)
  handlers = h
end

---Map the mouse keys in normal and terminal mode to these handlers. Mapping again replaces the
-- same maps, so calling it twice is harmless.
function M.setup()
  local drag_modes = { "n", "t" }
  local drag_desc = "Move/resize harness float by its border"
  vim.keymap.set(drag_modes, "<LeftMouse>", function()
    return M.press(vim.fn.getmousepos())
  end, { expr = true, desc = drag_desc })
  vim.keymap.set(drag_modes, "<LeftDrag>", function()
    return M.drag(vim.fn.getmousepos())
  end, { expr = true, desc = drag_desc })
  vim.keymap.set(drag_modes, "<LeftRelease>", function()
    return M.release()
  end, { expr = true, desc = drag_desc })
  vim.keymap.set(drag_modes, "<2-LeftMouse>", function()
    return M.double(vim.fn.getmousepos())
  end, { expr = true, desc = "Minimize/restore harness float" })
end

return M
