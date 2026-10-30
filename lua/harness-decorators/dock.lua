-- The dock of minimized bars: each minimized harness float becomes a one-line bar stacked in the
-- top-right corner. Owns the bar windows and their slots; term.lua owns the floats.
local M = {}

local state = require("harness-decorators.state")
local layout = require("harness-decorators.layout")
local float_util = require("harness-decorators.float-util")
local BAR_HEIGHT, BAR_MIN_TEXT = layout.BAR_HEIGHT, layout.BAR_MIN_TEXT
local zen_active, zen_float_span, auto_float_rect = layout.zen_active, layout.zen_float_span, layout.auto_float_rect
local dock_row, drawn_pos = layout.dock_row, layout.drawn_pos
local find_base_window, grip_title = float_util.find_base_window, float_util.grip_title

---True if the instance is minimized to a bar whose window is still valid.
---@param inst table?
---@return boolean
function M.has_bar(inst)
  return inst ~= nil and inst._pill_win ~= nil and vim.api.nvim_win_is_valid(inst._pill_win)
end

---Animate a bar to `to` ({ row, col, width, height }), then call on_done (see
-- terminal-animations.animate_win).
---@param inst table the Snacks terminal instance that owns the bar
---@param win integer the bar window
---@param to { row: integer, col: integer, width: integer, height: integer }
---@param on_done? fun()
function M.animate_win(inst, win, to, on_done)
  require("harness-decorators.terminal-animations").animate_win(inst, "_bar_anim", win, to, nil, on_done)
end

---The column a docked bar whose text is `width` columns wide starts at, so its right border sits on
-- the editor's last column.
---@param width integer
---@return integer col
function M.dock_col(width)
  local edge = vim.o.columns - width - 2
  if zen_active() then
    -- Just right of the rightmost visible harness float, by where it is headed (inst.opts, set by
    -- resize_to) or else where it is drawn.
    local span = zen_float_span()
    local right = span.col + span.width + 2
    for _, e in pairs(state.table) do
      local i = e.inst
      local bar = M.has_bar(i)
      if i and not bar and not i._shelf_mode and i.win and vim.api.nvim_win_is_valid(i.win) then
        local o = i.opts or {}
        local col, w = o.col, o.width
        if type(col) ~= "number" or type(w) ~= "number" or w < 1 then
          local cfg = vim.api.nvim_win_get_config(i.win)
          col, w = cfg.col, cfg.width
        end
        right = math.max(right, math.floor(col) + w + 2)
      end
    end
    edge = math.min(edge, right)
  end
  return math.max(0, edge)
end

---The lowest dock slot no other harness's bar holds.
---@return integer slot
function M.free_slot()
  local used = {}
  for _, e in pairs(state.table) do
    local i = e.inst
    if i and i._bar_slot and M.has_bar(i) then
      used[i._bar_slot] = true
    end
  end
  local slot = 1
  while used[slot] do
    slot = slot + 1
  end
  return slot
end

---Renumber docked bars 1..n in slot order (slot 1 is the top) and animate any that moved.
function M.repack_dock()
  local docked = {}
  for _, e in pairs(state.table) do
    local i = e.inst
    if i and i._bar_slot and M.has_bar(i) then
      table.insert(docked, i)
    end
  end
  table.sort(docked, function(a, b)
    return a._bar_slot < b._bar_slot
  end)
  for slot, i in ipairs(docked) do
    i._bar_slot = slot
    -- Target the bar's final size, not its current one: it may still be shrinking from its float.
    local cfg = vim.api.nvim_win_get_config(i._pill_win)
    local col = M.dock_col(i._bar_width)
    if math.floor(cfg.row) ~= dock_row(slot) or math.floor(cfg.col) ~= col or cfg.width ~= i._bar_width then
      M.animate_win(i, i._pill_win, { row = dock_row(slot), col = col, width = i._bar_width, height = 1 })
    end
  end
end

---Close the one-line minimized bar for this instance, if it has one.
---@param inst table the Snacks terminal instance
function M.close_pill(inst)
  if inst._bar_anim then
    inst._bar_anim:finish()
    inst._bar_anim = nil
  end
  if M.has_bar(inst) then
    pcall(vim.api.nvim_win_close, inst._pill_win, true)
  end
  inst._pill_win = nil
  if layout.get(inst) == "minimized" then
    layout.set(inst, "normal")
  end
  if inst._bar_slot then
    inst._bar_slot = nil
    M.repack_dock()
  end
end

---Hide the float and dock a one-line bar for it in the top-right; restore via bar double-click,
-- <leader>c or a re-pick.
---@param inst table the Snacks terminal instance
function M.minimize_float(inst)
  local harness = state.harness_of(inst)
  if not (harness and inst.win and vim.api.nvim_win_is_valid(inst.win)) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(inst.win)
  -- Name on the left, the restore/close icons together at the right end. Every bar is padded to at
  -- least BAR_MIN_TEXT columns so stacked bars line up and their icons sit in one column.
  local chunks = grip_title(harness)
  local name_width = 0
  for _, c in ipairs(chunks) do
    name_width = name_width + vim.fn.strdisplaywidth(c[1])
  end
  local icons = "⛶  ⊘ "
  local pad = math.max(1, BAR_MIN_TEXT - name_width - vim.fn.strdisplaywidth(icons))
  vim.list_extend(chunks, { { string.rep(" ", pad), "Normal" }, { icons, "Special" } })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local text = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks))
  -- Display column of the close icon within the bar's text, for the button hit test (bar_button).
  inst._bar_close_col = vim.fn.strdisplaywidth(text) - 2
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local ns = vim.api.nvim_create_namespace("harness_minimized")
  local byte = 0
  for _, c in ipairs(chunks) do
    vim.api.nvim_buf_set_extmark(buf, ns, 0, byte, { end_col = byte + #c[1], hl_group = c[2] })
    byte = byte + #c[1]
  end
  local row, col = drawn_pos(inst.win)
  local width = vim.fn.strdisplaywidth(text)
  -- Where the float was, so restoring can grow the bar back to it. A float in shelf mode (fullscreen
  -- or shelved) leaves shelf mode and restores to its normal spot, the same as a <C-q> switch.
  inst._restore_rect = { row = row, col = col, width = cfg.width, height = cfg.height }
  if inst._shelf_mode or layout.get(inst) ~= "normal" then
    local r = auto_float_rect()
    inst._restore_rect = vim.deepcopy(r)
    inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = r.row, r.col, r.width, r.height
  end
  layout.set(inst, "minimized")
  inst._bar_slot = M.free_slot()
  -- Hiding the focused float lets Neovim focus any window, including another harness float, which
  -- would then take the focused spot. Move focus off the harness floats first.
  if vim.api.nvim_get_current_win() == inst.win then
    local focus = require("harness-decorators.focus")
    focus.suppress_next_leave()
    local ok, zen = pcall(require, "zen-mode.view")
    if zen_active() and ok and zen.win and vim.api.nvim_win_is_valid(zen.win) then
      vim.api.nvim_set_current_win(zen.win)
    elseif not focus.jump_to_saved() then
      find_base_window()
    end
  end
  pcall(function()
    inst:hide()
  end)
  inst._pill_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = cfg.width,
    height = cfg.height,
    style = "minimal",
    border = "rounded",
    zindex = 60,
  })
  inst._bar_width = width
  M.animate_win(
    inst,
    inst._pill_win,
    { row = dock_row(inst._bar_slot), col = M.dock_col(width), width = width, height = 1 }
  )
end

---The instance whose minimized bar (border included) contains the given 1-based screen pos, and
-- that bar's window.
---@return table? inst
---@return integer? bar
function M.bar_hit(screenrow, screencol)
  for _, e in pairs(state.table) do
    local bar = e.inst and e.inst._pill_win
    if bar and vim.api.nvim_win_is_valid(bar) then
      local top, left = drawn_pos(bar)
      local width = vim.api.nvim_win_get_width(bar) + 2
      if screenrow > top and screenrow <= top + BAR_HEIGHT and screencol > left and screencol <= left + width then
        return e.inst, bar
      end
    end
  end
end

---Which of a minimized bar's buttons the given 1-based screen column hits: "restore" for the restore
-- icon and the cell on either side of it, "close" for the close icon, the cell on either side of it
-- and the bar's right border, nil anywhere else.
---@return "restore"|"close"|nil
function M.bar_button(inst, bar, screencol)
  local _, left = drawn_pos(bar)
  -- The bar's text starts one column in from its left border; screencol is 1-based.
  local x = screencol - (left + 2)
  local close = inst._bar_close_col
  if x >= close - 1 and x <= close + 2 then
    return "close"
  end
  if x >= close - 4 and x <= close - 2 then
    return "restore"
  end
end

---Grow a minimized instance's bar back out to where its float was (the reverse of minimize), then
-- call on_show. The terminal window itself is never resized, so the harness does not redraw at every
-- frame. Returns false, and does nothing, when the instance has no bar to grow.
---@param inst table the Snacks terminal instance
---@param on_show fun()
---@return boolean
function M.grow_back(inst, on_show)
  local bar = inst._pill_win
  if not (bar and vim.api.nvim_win_is_valid(bar) and inst._restore_rect) then
    return false
  end
  -- A restoring bar leaves the dock, so a re-tile's dock repack does not pull it back.
  if inst._bar_slot then
    inst._bar_slot = nil
    M.repack_dock()
  end
  M.animate_win(inst, bar, inst._restore_rect, function()
    -- The bar may have been closed (or reused) while it was growing.
    if inst._pill_win == bar then
      on_show()
    end
  end)
  return true
end

return M
