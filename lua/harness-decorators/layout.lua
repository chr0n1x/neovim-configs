-- Geometry for harness floats and minimized bars: the editor-relative rects each float layout
-- uses, small predicates over window positions, and get/set for a float's layout (kept on its
-- Snacks instance).
local M = {}

-- Rows a minimized bar takes on screen: its one line of text plus the top and bottom border.
M.BAR_HEIGHT = 3
-- Minimum width of a minimized bar's text, so bars for short harness names match the longer ones.
M.BAR_MIN_TEXT = 18

-- Default float size and spot, as fractions of the editor.
M.FLOAT_ROW, M.FLOAT_WIDTH, M.FLOAT_HEIGHT = 0, 0.30, 0.90
M.ZEN_MIN_WIDTH, M.ZEN_HEIGHT = 0.20, 0.70

-- <C-f> fullscreen padding, as fractions of the editor.
M.FULL_ROW_PAD, M.FULL_COL_PAD = 0.05, 0.1

-- Text rows a shelved float keeps (see term's shelve). Specs set layout.shelf_rows directly.
M.shelf_rows = 10

-- When not nil, zen_active returns it instead of asking zen-mode. Specs set
-- layout.zen_active_override directly.
M.zen_active_override = nil

---True when zen mode is currently open.
---@return boolean
function M.zen_active()
  if M.zen_active_override ~= nil then
    return M.zen_active_override
  end
  local ok, zen = pcall(require, "zen-mode.view")
  return ok and zen.is_open and zen.is_open() and true or false
end

---The editor as the rect functions see it. Every rect function takes one (or builds it from the
-- live editor when nil), so specs can call them without windows.
---@class harness.Screen
---@field lines integer
---@field columns integer
---@field zen_open boolean zen mode is open (zen_active)
---@field zen? { col: number, width: integer, border?: any } the zen window's config, when one exists

---The live editor's screen.
---@return harness.Screen
function M.screen()
  local zwin = require("util.zen").win()
  return {
    lines = vim.o.lines,
    columns = vim.o.columns,
    zen_open = M.zen_active(),
    zen = zwin and vim.api.nvim_win_get_config(zwin) or nil,
  }
end

---The default float column: 2 cols left of the right edge, shifted further left when that would
-- put the float under the minimized-bar dock (top-right).
---@return integer col
---@param screen? harness.Screen
function M.default_float_col(screen)
  local cols = (screen or M.screen()).columns
  local w = math.floor(cols * M.FLOAT_WIDTH)
  local col = cols - w - 2
  local dock_left = cols - (M.BAR_MIN_TEXT + 2)
  col = math.min(col, dock_left - 1 - w)
  return math.max(0, col)
end

---The harness float's columns while zen mode is open: starting a quarter of the way into the zen
-- window and 90% of the zen-mode gap (the space from the zen window's right edge to the dock's
-- left edge), shifted left when needed so the minimized-bar dock fits on its right; on an editor
-- too small for both it overlaps the dock. With no zen window to measure, ZEN_MIN_WIDTH of the
-- editor ending where the dock begins.
---@return { col: integer, width: integer } width excludes the border
---@param screen? harness.Screen
function M.zen_float_span(screen)
  screen = screen or M.screen()
  local cols = screen.columns
  local dock_room = M.BAR_MIN_TEXT + 2
  local outer = math.floor(cols * M.ZEN_MIN_WIDTH)
  local left = cols - dock_room - outer
  local zcfg = screen.zen
  if zcfg then
    local zright = math.floor(zcfg.col) + zcfg.width
    local gap = math.max(0, cols - dock_room - zright)
    outer = math.max(3, math.ceil(gap * 0.9))
    left = math.floor(zcfg.col) + math.floor(zcfg.width / 4)
  end
  left = math.max(0, math.min(left, cols - dock_room - outer))
  return { col = left, width = outer - 2 }
end

---The unfocused harness float's columns while zen mode is open: 55% of the zen-mode gap (the space
-- from the zen window's right edge to the dock's left edge), starting one column right of the zen
-- window.
---@return { col: integer, width: integer } width excludes the border
---@param screen? harness.Screen
function M.zen_side_span(screen)
  screen = screen or M.screen()
  local span = M.zen_float_span(screen)
  local left = span.col
  local zcfg = screen.zen
  if zcfg then
    local zborder = zcfg.border ~= nil and zcfg.border ~= "none" and not vim.tbl_isempty(zcfg.border)
    local zright = math.floor(zcfg.col) + zcfg.width + (zborder and 2 or 0) -- first column right of zen
    local dock_room = M.BAR_MIN_TEXT + 2
    local zinner_right = zright - (zborder and 2 or 0) -- zen right edge excluding border
    local gap = math.max(0, screen.columns - dock_room - zinner_right)
    local outer = math.max(3, math.floor(gap * 0.55))
    left = zright + 1
    return { col = left, width = outer - 2 }
  end
  return { col = left, width = span.width }
end

---The default right-side float's rect, resolved the way Snacks resolves win_opts: a fractional size
-- includes the border, a fractional row strictly between 0 and 1 is counted below the top border,
-- and any other row is used as-is.
---@return { row: integer, col: integer, width: integer, height: integer }
---@param screen? harness.Screen
function M.default_float_rect(screen)
  screen = screen or M.screen()
  local lines, cols = screen.lines, screen.columns
  local row = (M.FLOAT_ROW > 0 and M.FLOAT_ROW < 1) and math.floor(lines * M.FLOAT_ROW) + 1 or M.FLOAT_ROW
  return {
    row = row,
    col = M.default_float_col(screen),
    width = math.floor(cols * M.FLOAT_WIDTH) - 2,
    height = math.floor(lines * M.FLOAT_HEIGHT) - 2,
  }
end

---The <C-f> fullscreen rect for the current editor size. While zen is open it keeps the zen float's
-- width, centered.
---@return { row: integer, col: integer, width: integer, height: integer }
---@param screen? harness.Screen
function M.fullscreen_rect(screen)
  screen = screen or M.screen()
  local lines, cols = screen.lines, screen.columns
  local rect = {
    row = math.floor(M.FULL_ROW_PAD * lines),
    col = math.floor(M.FULL_COL_PAD * cols),
    width = math.floor((1 - 2 * M.FULL_COL_PAD) * cols),
    height = math.floor((1 - 2 * M.FULL_ROW_PAD) * lines),
  }
  if screen.zen_open then
    rect.width = M.zen_float_span(screen).width
    rect.col = math.floor((cols - rect.width - 2) / 2)
  end
  return rect
end

---The shelf: shelf_rows rows at the bottom of the fullscreen rect, the normal float's width (the
-- zen float's while zen is open), centered.
---@return { row: integer, col: integer, width: integer, height: integer }
---@param screen? harness.Screen
function M.shelf_rect(screen)
  screen = screen or M.screen()
  local full = M.fullscreen_rect(screen)
  local cols = screen.columns
  local rows = math.min(M.shelf_rows, full.height)
  local width = screen.zen_open and M.zen_float_span(screen).width or math.floor(cols * M.FLOAT_WIDTH) - 2
  return { row = full.row + full.height - rows, col = math.floor((cols - width - 2) / 2), width = width, height = rows }
end

---True when the window is an editor float sitting exactly on `rect`.
---@return boolean
function M.at_rect(win, rect)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative == "editor"
    and math.floor(cfg.row) == rect.row
    and math.floor(cfg.col) == rect.col
    and cfg.width == rect.width
    and cfg.height == rect.height
end

---Where an unmoved float sits: while zen is open, the zen spot when `win` is focused or not given
-- and the gap right of zen when another window has focus; else the default right-side spot.
---@param win? integer the float's window
---@param screen? harness.Screen
---@param aside? boolean whether another window has focus; worked out from `win` when nil
---@return { row: integer, col: integer, width: integer, height: integer }
function M.auto_float_rect(win, screen, aside)
  screen = screen or M.screen()
  local rect = M.default_float_rect(screen)
  if screen.zen_open then
    if aside == nil then
      aside = win ~= nil and vim.api.nvim_get_current_win() ~= win
    end
    local span = aside and M.zen_side_span(screen) or M.zen_float_span(screen)
    rect.col, rect.width = span.col, span.width
    rect.height = math.floor(screen.lines * M.ZEN_HEIGHT) - 2
  end
  return rect
end

---Where a fullscreen float retracts to: the unmoved spot for the current layout (zen-aware) when the
-- float sat there before going fullscreen or nothing was saved, else the saved geometry.
---@param self table the Snacks terminal instance
---@param screen? harness.Screen
---@return { row: integer, col: integer, width: integer, height: integer }
function M.retract_rect(self, screen)
  screen = screen or M.screen()
  local sc = self._saved_config
  if not sc or sc.auto then
    return M.auto_float_rect(self.win, screen)
  end
  local lines, cols = screen.lines, screen.columns
  return {
    row = math.floor((sc.row_ratio or 0) * lines),
    col = math.floor((sc.col_ratio or 0) * cols),
    width = math.floor((sc.width_ratio or 1) * cols),
    height = math.floor((sc.height_ratio or 1) * lines),
  }
end

---Minimized bars dock in the top-right corner of the editor and stack downward: slot 1 sits at the
-- top (below the tabline when one is shown), slot 2 below it, and so on.
---@param slot integer
---@return integer row
function M.dock_row(slot)
  local stal = vim.o.showtabline
  local top = (stal == 2 or (stal == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
  return top + M.BAR_HEIGHT * (slot - 1)
end

---`n` rects in a grid `outer_width` wide (border included) starting at `col`, filled row by row,
-- over the default float height: one per row up to 3, then 2 per row, then 3, so there are at most 3
-- rows. Rows and columns split the space evenly; the last row/column takes the remainder. Cells
-- that have a neighbour to their right or below give up one column or row as a gap.
---@param screen? harness.Screen
---@return { row: integer, col: integer, width: integer, height: integer }[]
function M.stack_rects(n, col, outer_width, screen)
  local total = math.floor((screen and screen.lines or vim.o.lines) * M.FLOAT_HEIGHT)
  local per_row = math.max(1, math.ceil(n / 3))
  local nrows = math.ceil(n / per_row)
  local rects = {}
  for k = 0, n - 1 do
    local r, c = math.floor(k / per_row), k % per_row
    local h = math.floor(total / nrows)
    local w = math.floor(outer_width / per_row)
    local row, x = r * h, col + c * w
    if r == nrows - 1 then
      h = total - row
    else
      h = h - 1
    end
    if c == per_row - 1 then
      w = outer_width - c * w
    else
      w = w - 1
    end
    table.insert(rects, { row = row, col = x, width = math.max(1, w - 2), height = math.max(1, h - 2) })
  end
  return rects
end

---Where a harness float is, as one value on its Snacks instance (inst._layout):
--   "normal"     its own spot (default, zen, tiled, or wherever the user dragged it)
--   "fullscreen" the <C-f> fullscreen rect
--   "shelved"    the shelf at the bottom of the fullscreen rect
--   "minimized"  hidden, with a bar in the dock
-- Shelf mode (inst._shelf_mode) is separate: a policy that makes focus drive the float between
-- fullscreen and the shelf. It can be on in "normal" (the float was dragged off fullscreen, and
-- focus takes it back) and off in "fullscreen" (the shelf button turned it off).
---@alias harness.Layout "normal"|"fullscreen"|"shelved"|"minimized"

---The instance's layout; "normal" when none was set.
---@param inst table the Snacks terminal instance
---@return harness.Layout
function M.get(inst)
  return inst._layout or "normal"
end

---The one place a float's layout changes. It keeps the related fields consistent:
--   * "shelved" turns shelf mode on; "minimized" turns it off and drops the <C-f> baseline.
--   * opts.shelf_mode sets shelf mode explicitly; opts.forget_baseline drops the baseline.
-- Otherwise the baseline (_saved_config) is kept, so toggling <C-f> does not drift the float.
---@param inst table the Snacks terminal instance
---@param to harness.Layout
---@param opts? { shelf_mode?: boolean, forget_baseline?: boolean }
function M.set(inst, to, opts)
  opts = opts or {}
  inst._layout = to
  if opts.shelf_mode ~= nil then
    inst._shelf_mode = opts.shelf_mode
  end
  if to == "shelved" then
    inst._shelf_mode = true
  elseif to == "minimized" then
    inst._shelf_mode = false
  end
  if to == "minimized" or opts.forget_baseline then
    inst._saved_config = nil
  end
end

---The 0-based screen row/col of a float's outer top-left corner (border included) as drawn.
-- Neovim shifts a float that would not fit back onto the screen, so after an editor resize or a
-- restore near the edge the drawn spot can differ from the row/col in its config.
---@return integer row
---@return integer col
function M.drawn_pos(win)
  local pos = vim.api.nvim_win_get_position(win)
  return pos[1], pos[2]
end

return M
