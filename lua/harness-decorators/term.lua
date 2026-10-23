-- Per-harness floating terminal owner (Task 7; Task 8 consolidated the state).
--
-- The terminal layer no longer routes through claudecode.nvim's single module-level `terminal`
-- handle (the "maki shows claude" bug: one shared handle means opening a different harness can
-- re-show the previous harness's parked buffer). Instead each harness drives its OWN Snacks
-- floating terminal, and this module keeps them in the SHARED per-harness state table
-- (harness-decorators/state.lua), keyed by harness name:
--
--   state.table[harness].inst = snacks.terminal instance  -- has .buf, .win, :show(), :hide(), :buf_valid()
--
-- Snacks.terminal already keeps its OWN registry (terminals[tid]), so N independent floats work
-- natively; we just add a per-harness key on top and resolve each harness's spawn command at call
-- time from its env module (harness-decorators/<harness>/env.lua). This module is deliberately free
-- of any claudecode require - context injection (context-inject.lua) finds the visible terminal
-- window by scanning, so it never needs our handle either. The float's keys and resize animation
-- that used to live in plugins/ai-harness.lua now live here (win_opts), so the whole terminal layer
-- is owned by this module. Selection state lives on the same record (state.table[harness].selected)
-- and is managed by park.lua - this module only ever touches `.inst`. See docs/multi-agent-prd.md.
local M = {}

local state = require("harness-decorators.state")
local title = require("harness-decorators.title")

local auto_insert_group = vim.api.nvim_create_augroup("HarnessTerminalAutoInsert", { clear = true })

local function mark_harness_buffer(harness, inst)
  if inst and inst.buf and vim.api.nvim_buf_is_valid(inst.buf) then
    vim.b[inst.buf].harness_terminal = harness
  end
end

---Log a terminal-mode transition event with full guard state to a grep-able file and
-- :messages. Used by every guard in enter_terminal_mode so a stuck state (terminal in
-- terminal-normal when it should be in terminal-insert) can be diagnosed from the artifact
-- without scrolling the message history. One line per event.
local function dbg(tag, buf, detail)
  local line = string.format(
    "%s | %s | cur=%s curbuf=%s buftype=%s mark=%s mode=%s normal_mode=%s",
    os.date("%H:%M:%S"),
    tag,
    tostring(vim.api.nvim_get_current_win()),
    tostring(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())),
    (buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype) or "invalid",
    (buf and vim.api.nvim_buf_is_valid(buf) and tostring(vim.b[buf].harness_terminal)) or "invalid",
    vim.fn.mode(1),
    (buf and vim.api.nvim_buf_is_valid(buf) and tostring(vim.b[buf].harness_terminal_normal_mode)) or "n/a"
  )
  if detail then
    line = line .. " | " .. detail
  end
  local log_path = "/tmp/harness-term-focus.log"
  local f = io.open(log_path, "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
  vim.notify(line, vim.log.levels.DEBUG)
  return line
end

---True while windows.nvim is animating a split resize. Its animation runs `feedkeys("ze", "nx")` in
-- the CURRENT window on every frame; when that window is a harness terminal with a startinsert
-- pending, the feedkeys drops the terminal to terminal-normal on every frame and can leave Neovim
-- stuck there. This happens when the float opens right after focus returns to a split (closing the
-- <C-q> picker restarts the animation in the split it lands on).
---@return boolean
local function windows_resize_animating()
  local R = package.loaded["windows.lib.resize-windows-animated"]
  local anim = type(R) == "table" and R._instance
  return anim ~= nil and anim ~= false and anim:is_running()
end

-- Longest enter_terminal_mode waits on a windows.nvim resize. Its animation is 300ms, but a window
-- closed mid-animation makes the animation's callback error, which leaves it reporting running
-- forever; past this the wait gives up and enters terminal mode anyway.
local RESIZE_WAIT_MAX_MS = 1000

---@param waited? integer ms already spent waiting on a windows.nvim resize
local function enter_terminal_mode(win, buf, waited)
  waited = waited or 0
  if waited < RESIZE_WAIT_MAX_MS and windows_resize_animating() then
    dbg("enter_terminal_mode WAIT: windows.nvim resize animating", buf)
    vim.defer_fn(function()
      enter_terminal_mode(win, buf, waited + 20)
    end, 20)
    return
  end
  if not vim.api.nvim_win_is_valid(win) then
    dbg("enter_terminal_mode DROPPED: win invalid", buf, "win=" .. tostring(win))
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    dbg("enter_terminal_mode DROPPED: buf invalid", buf, "buf=" .. tostring(buf))
    return
  end
  if vim.api.nvim_get_current_win() ~= win then
    dbg("enter_terminal_mode DROPPED: current win mismatch", buf, "got win=" .. tostring(win))
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    dbg(
      "enter_terminal_mode DROPPED: win shows different buf",
      buf,
      "win shows " .. tostring(vim.api.nvim_win_get_buf(win))
    )
    return
  end
  if vim.bo[buf].buftype ~= "terminal" then
    dbg("enter_terminal_mode DROPPED: not a terminal buftype", buf)
    return
  end
  if not vim.b[buf].harness_terminal then
    dbg("enter_terminal_mode DROPPED: buffer lost harness mark", buf)
    return
  end
  if vim.fn.mode(1) == "t" then
    dbg("enter_terminal_mode SKIP: already in terminal mode", buf)
    return
  end
  if vim.b[buf].harness_terminal_normal_mode then
    dbg("enter_terminal_mode SKIP: user pressed <C-n>", buf)
    return
  end
  dbg("enter_terminal_mode: startinsert", buf)
  vim.cmd.startinsert()
end

-- Forward-declared so the autocmds below (defined before the real function in file order) can
-- close over it. Reassigned to the real implementation further down; autocmd callbacks only run
-- after the module is fully loaded, by which point this local points at the real function.
local schedule_enter_terminal_mode

local function harness_terminal_buf()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].harness_terminal then
    return buf
  end
  return nil
end

vim.api.nvim_create_autocmd("WinEnter", {
  group = auto_insert_group,
  callback = function()
    local buf = harness_terminal_buf()
    if buf then
      dbg("WinEnter autocmd", buf)
      schedule_enter_terminal_mode(vim.api.nvim_get_current_win(), buf)
    end
  end,
})

-- Re-focusing nvim (e.g. clicking the window, switching from another terminal) restores terminal
-- insert mode: some window managers and remote setups drop terminal insert mode on focus loss.
vim.api.nvim_create_autocmd("FocusGained", {
  group = auto_insert_group,
  callback = function()
    local buf = harness_terminal_buf()
    -- A user who pressed <C-n> deliberately wants normal mode; FocusGained must not yank them back
    -- into insert (schedule_enter_terminal_mode clears the flag, so only the deliberate re-focus
    -- paths may reset it).
    if buf and not vim.b[buf].harness_terminal_normal_mode then
      dbg("FocusGained autocmd", buf)
      schedule_enter_terminal_mode(vim.api.nvim_get_current_win(), buf)
    end
  end,
})

-- Log every TermLeave from a harness terminal so the debug log shows what kicks it out of terminal
-- mode.
vim.api.nvim_create_autocmd("TermLeave", {
  group = auto_insert_group,
  callback = function()
    local buf = harness_terminal_buf()
    if buf then
      dbg("TermLeave autocmd", buf)
    end
  end,
})

---Enter terminal mode for (win, buf) on the next tick: snacks.open and a re-focus both return before
-- the window/buffer has settled, so a synchronous startinsert does not reliably stick. The
-- WinEnter/FocusGained autocmds only fire when focus actually moves, so re-selecting a harness whose
-- float already has focus (e.g. pressing <leader>c a second time while sitting in it) never triggers
-- them; every focus/open path in this module calls this directly.
---@param win integer?
---@param buf integer?
schedule_enter_terminal_mode = function(win, buf)
  if not win or not buf then
    dbg(
      "schedule_enter_terminal_mode DROPPED: nil win/buf",
      buf,
      string.format("win=%s buf=%s", tostring(win), tostring(buf))
    )
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].harness_terminal_normal_mode = false
  end
  dbg("schedule_enter_terminal_mode", buf)
  vim.schedule(function()
    enter_terminal_mode(win, buf)
  end)
end

-- Exposed on M so it is stubbable from tests; the autocmds above close over the local, which is the
-- same function.
M.schedule_enter_terminal_mode = schedule_enter_terminal_mode

---The shared per-harness record for `harness`, creating it if absent.
-- Every instance read/write in this module goes through the single accessor in state.lua so term
-- and park never diverge (Task 8).
---@param harness string
---@return table entry { inst = snacks.terminal|nil, selected = boolean }
local function entry(harness)
  return state.entry(harness)
end

---True if the given Snacks instance still has a valid buffer. Must be called with method syntax
-- (`inst:buf_valid()`) - Snacks.win:buf_valid is defined as `function M:buf_valid()` and indexes
-- `self.buf`, so calling it as a plain function (`inst.buf_valid()`) passes nil for self and E5108s.
---@param inst table?
---@return boolean
local function is_live(inst)
  if not inst or type(inst.buf_valid) ~= "function" then
    return false
  end
  local ok, valid = pcall(function()
    return inst:buf_valid()
  end)
  return ok and valid == true
end

---Resolve the command a harness's terminal should run, reading its env module at call time so a
---later re-point (or an env override like CLAUDE_COMMAND) is always honored.
---@param harness string
---@return string? cmd
local function resolve_cmd(harness)
  local ok, cmd = pcall(require, "harness-decorators." .. harness .. ".env")
  if not ok or type(cmd) ~= "string" then
    return nil
  end
  return cmd
end

---Find the window beside the floating terminal - no cleaner way exists (still). Specifically written
-- to go back to the previous window BECAUSE we're using a floating terminal. Ported verbatim from
-- plugins/ai-harness.lua so the go-back behavior is unchanged.
local function valid_buf(win_id)
  local config = vim.api.nvim_win_get_config(win_id)
  local buf_info = vim.api.nvim_win_get_buf(win_id)
  local buf_name = vim.api.nvim_buf_get_name(buf_info)
  local terminal_win = vim.api.nvim_get_current_win()

  return not config.z and win_id ~= terminal_win and vim.uv.fs_stat(buf_name) ~= nil
end

local function find_base_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)

  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    if valid_buf(win_id) then
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end
end

local function set_prev_win()
  find_base_window()
end

-- Rows a minimized bar takes on screen: its one line of text plus the top and bottom border.
local BAR_HEIGHT = 3
-- Minimum width of a minimized bar's text, so bars for short harness names match the longer ones.
local BAR_MIN_TEXT = 18

-- Default float size and spot, as fractions of the editor.
local FLOAT_ROW, FLOAT_WIDTH, FLOAT_HEIGHT = 0, 0.30, 0.90
local ZEN_MIN_WIDTH, ZEN_HEIGHT = 0.20, 0.70

---The default float column: 2 cols left of the right edge, shifted further left when that would
-- put the float under the minimized-bar dock (top-right).
---@return integer col
local function default_float_col()
  local cols = vim.o.columns
  local w = math.floor(cols * FLOAT_WIDTH)
  local col = cols - w - 2
  local dock_left = cols - (BAR_MIN_TEXT + 2)
  col = math.min(col, dock_left - 1 - w)
  return math.max(0, col)
end

---The harness float's columns while zen mode is open: starting a quarter of the way into the zen
-- window and 10% wider than it (at least as wide as the tiling grid's widest cell), shifted left
-- when needed so the minimized-bar dock fits on its right; on an editor too small for both it
-- overlaps the dock. With no zen window to measure, ZEN_MIN_WIDTH of the editor ending where the
-- dock begins.
---@return { col: integer, width: integer } width excludes the border
local function zen_float_span()
  local cols = vim.o.columns
  local dock_room = BAR_MIN_TEXT + 2
  local outer = math.floor(cols * ZEN_MIN_WIDTH)
  local left = cols - dock_room - outer
  local ok, zen = pcall(require, "zen-mode.view")
  local zwin = ok and zen.is_open and zen.is_open() and zen.win
  if zwin and vim.api.nvim_win_is_valid(zwin) then
    local zcfg = vim.api.nvim_win_get_config(zwin)
    -- At least as wide as the grid's widest cell: half the empty area left of zen (see M.tile).
    local grid_cell = math.floor((math.floor(zcfg.col) - 1) / 2)
    outer = math.max(grid_cell, zcfg.width + math.floor(zcfg.width / 10))
    left = math.floor(zcfg.col) + math.floor(zcfg.width / 4)
  end
  left = math.max(0, math.min(left, cols - dock_room - outer))
  return { col = left, width = outer - 2 }
end

---The unfocused harness float's columns while zen mode is open: the zen spot shrunk from the left,
-- so it keeps the zen spot's right edge and starts one column right of the zen window.
---@return { col: integer, width: integer } width excludes the border
local function zen_side_span()
  local span = zen_float_span()
  local right = span.col + span.width + 2 -- one past the last column
  local left = span.col
  local ok, zen = pcall(require, "zen-mode.view")
  local zwin = ok and zen.is_open and zen.is_open() and zen.win
  if zwin and vim.api.nvim_win_is_valid(zwin) then
    local zcfg = vim.api.nvim_win_get_config(zwin)
    local zborder = zcfg.border ~= nil and zcfg.border ~= "none" and not vim.tbl_isempty(zcfg.border)
    local zright = math.floor(zcfg.col) + zcfg.width + (zborder and 2 or 0) -- first column right of zen
    -- Leave room for the border and one text column.
    left = math.max(left, math.min(zright + 1, right - 3))
  end
  return { col = left, width = right - left - 2 }
end

---The default right-side float's rect, resolved the way Snacks resolves win_opts: a fractional size
-- includes the border, a fractional row strictly between 0 and 1 is counted below the top border,
-- and any other row is used as-is.
---@return { row: integer, col: integer, width: integer, height: integer }
local function default_float_rect()
  local lines, cols = vim.o.lines, vim.o.columns
  local row = (FLOAT_ROW > 0 and FLOAT_ROW < 1) and math.floor(lines * FLOAT_ROW) + 1 or FLOAT_ROW
  return {
    row = row,
    col = default_float_col(),
    width = math.floor(cols * FLOAT_WIDTH) - 2,
    height = math.floor(lines * FLOAT_HEIGHT) - 2,
  }
end

-- <C-f> fullscreen padding, as fractions of the editor.
local FULL_ROW_PAD, FULL_COL_PAD = 0.05, 0.1

local zen_active -- forward declaration; defined below
local retile -- forward declaration; defined below
local scroll_to_bottom -- forward declaration; defined below

---The <C-f> fullscreen rect for the current editor size. While zen is open it keeps the zen float's
-- width, centered.
---@return { row: integer, col: integer, width: integer, height: integer }
local function fullscreen_rect()
  local lines, cols = vim.o.lines, vim.o.columns
  local rect = {
    row = math.floor(FULL_ROW_PAD * lines),
    col = math.floor(FULL_COL_PAD * cols),
    width = math.floor((1 - 2 * FULL_COL_PAD) * cols),
    height = math.floor((1 - 2 * FULL_ROW_PAD) * lines),
  }
  if zen_active() then
    rect.width = zen_float_span().width
    rect.col = math.floor((cols - rect.width - 2) / 2)
  end
  return rect
end

-- Text rows a shelved float keeps (see shelve). On M so specs can read it.
M.shelf_rows = 10

---The shelf: M.shelf_rows rows at the bottom of the fullscreen rect, the normal float's width (the
-- zen float's while zen is open), centered.
---@return { row: integer, col: integer, width: integer, height: integer }
local function shelf_rect()
  local full = fullscreen_rect()
  local cols = vim.o.columns
  local rows = math.min(M.shelf_rows, full.height)
  local width = zen_active() and zen_float_span().width or math.floor(cols * FLOAT_WIDTH) - 2
  return { row = full.row + full.height - rows, col = math.floor((cols - width - 2) / 2), width = width, height = rows }
end

---True when the window is an editor float sitting exactly on `rect`.
---@return boolean
local function at_rect(win, rect)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative == "editor"
    and math.floor(cfg.row) == rect.row
    and math.floor(cfg.col) == rect.col
    and cfg.width == rect.width
    and cfg.height == rect.height
end

---Animate the float to `rect` and keep that geometry in inst.opts, so Snacks reopens it there after
-- hide/show. _resized_at is stamped at both ends so the terminal's reflow for the new size is not
-- taken for new output (watch_output).
---@param inst table the Snacks terminal instance
---@param rect { row: integer, col: integer, width: integer, height: integer }
---@param on_done? fun() runs once the animation lands (not when a newer resize cuts it off)
local function resize_to(inst, rect, on_done)
  inst._resized_at = vim.uv.now()
  inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = rect.row, rect.col, rect.width, rect.height
  require("harness-decorators.terminal-animations").animate_resize(inst, rect, nil, function()
    inst._resized_at = vim.uv.now()
    -- An unfocused float keeps tailing its output at the new size.
    if inst.win and vim.api.nvim_get_current_win() ~= inst.win then
      scroll_to_bottom(inst)
    end
    if on_done then
      on_done()
    end
  end)
end

---Where an unmoved float sits: while zen is open, the zen spot when `win` is focused or not given
-- and the gap right of zen when another window has focus; else the default right-side spot.
---@param win? integer the float's window
---@return { row: integer, col: integer, width: integer, height: integer }
local function auto_float_rect(win)
  local rect = default_float_rect()
  if zen_active() then
    local aside = win ~= nil and vim.api.nvim_get_current_win() ~= win
    local span = aside and zen_side_span() or zen_float_span()
    rect.col, rect.width = span.col, span.width
    rect.height = math.floor(vim.o.lines * ZEN_HEIGHT) - 2
  end
  return rect
end

---Save the float's current geometry as the <C-f> retract target, unless one is saved already (so
-- repeated toggles don't drift it). Stored as RATIOS of the editor size, so an editor resize before
-- the retract is absorbed: retract_rect re-derives absolute coords against the size at that point.
---@param self table the Snacks terminal instance
local function save_baseline(self)
  if self._saved_config then
    return
  end
  local lines, cols = vim.o.lines, vim.o.columns
  local cfg = vim.api.nvim_win_get_config(self.win)
  self._saved_config = {
    auto = at_rect(self.win, auto_float_rect(self.win)),
    row_ratio = (cfg.row or 0) / lines,
    col_ratio = (cfg.col or 0) / cols,
    width_ratio = (cfg.width or cols) / cols,
    height_ratio = (cfg.height or lines) / lines,
  }
end

---Where a fullscreen float retracts to: the unmoved spot for the current layout (zen-aware) when the
-- float sat there before going fullscreen or nothing was saved, else the saved geometry.
---@param self table the Snacks terminal instance
---@return { row: integer, col: integer, width: integer, height: integer }
local function retract_rect(self)
  local sc = self._saved_config
  if not sc or sc.auto then
    return auto_float_rect(self.win)
  end
  local lines, cols = vim.o.lines, vim.o.columns
  return {
    row = math.floor((sc.row_ratio or 0) * lines),
    col = math.floor((sc.col_ratio or 0) * cols),
    width = math.floor((sc.width_ratio or 1) * cols),
    height = math.floor((sc.height_ratio or 1) * lines),
  }
end

---Collapse a <C-f>-widened float (_wide) back to its saved geometry, animated. Ported from
-- ai-harness.lua; the animation helper is shared (harness-decorators/terminal-animations.lua).
local function animate_collapse(self)
  if not (self._wide and self._saved_config) then
    return
  end
  self._wide = false
  resize_to(self, retract_rect(self))
end

local minimize_float -- forward declaration; defined below
local shelve -- forward declaration; defined below

---With shelf mode on and the float focused at fullscreen inside tmux, move to the tmux pane in `dir`
-- ("L" or "R") and leave the float focused and fullscreen. Returns true when it moved.
---@param self table the Snacks terminal instance
---@param dir "L"|"R"
---@return boolean
local function shelf_tmux_nav(self, dir)
  local win = self.win
  if not (self._shelf_mode and vim.env.TMUX and win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if vim.api.nvim_get_current_win() ~= win or not at_rect(win, fullscreen_rect()) then
    return false
  end
  vim.fn.system({ "tmux", "select-pane", "-" .. dir })
  return true
end

---Jump to the window we came from (the zen window while zen is open), collapsing a <C-f>-widened
-- float first.
---@param self table the Snacks terminal instance
local function go_back(self)
  local focus = require("harness-decorators.focus")
  focus.suppress_next_leave()
  animate_collapse(self)
  if zen_active() then
    -- Jump to the zen window (a float) instead of the saved parent window so
    -- zen-mode's WinEnter autocmd doesn't close zen mode.
    local ok, zen = pcall(require, "zen-mode.view")
    if ok and zen.win and vim.api.nvim_win_is_valid(zen.win) then
      vim.api.nvim_set_current_win(zen.win)
    else
      focus.jump_to_saved()
    end
  elseif not focus.jump_to_saved() then
    set_prev_win()
  end
  vim.cmd.redraw()
  vim.cmd("noh")
end

---The <C-h> go-back key handler: jump to the window we came from while THIS harness's float stays
-- open and visible. We do NOT hide it - the float is a separate window, so its PTY keeps running
-- regardless of where focus is; hiding would make the panel disappear, which is not what "go back"
-- should do. The collapse animation (if widened via <C-f>) still runs so the float returns to its
-- normal size. With shelf mode on and the float focused at fullscreen inside tmux, it moves to the
-- tmux pane on the left instead. Exposed on M (not a local) so tests/go_back_key_spec.lua can drive
-- it with a fake instance and assert the float is NOT hidden.
---@param self table the Snacks terminal instance (has :hide(), :show())
function M.go_back_key(self)
  if self._shelf_mode then
    shelf_tmux_nav(self, "L")
    return
  end
  go_back(self)
end

---The <Esc> close key handler: exit terminal insert mode and minimize this harness's float into its
-- docked bar (same as the float's minimize button). The process keeps running, so the same session
-- resumes from the bar, <leader>c or a re-pick. With shelf mode on it slides the float to the shelf
-- and goes back instead. An instance with no open float to minimize is hidden instead. Exposed on M
-- so tests/go_back_key_spec.lua can drive it with a fake instance.
---@param self table the Snacks terminal instance (has :hide(), :show())
function M.close_key(self)
  -- stopinsert is a no-op unless we're in terminal insert mode; guard it so the handler is safe to
  -- drive from a headless normal-mode context (tests) and never errors if already out of insert.
  pcall(vim.cmd.stopinsert)
  if self._shelf_mode and self.win and vim.api.nvim_win_is_valid(self.win) then
    shelve(self)
    go_back(self)
    return
  end
  for harness, e in pairs(state.table) do
    if e.inst == self and M.minimize(harness) then
      return
    end
  end
  pcall(function()
    self:hide()
  end)
end

function M.ensure_terminal_mode()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.b[buf].harness_terminal then
    return
  end
  vim.b[buf].harness_terminal_normal_mode = false
  vim.schedule(function()
    enter_terminal_mode(win, buf)
  end)
end

---The <C-n> key handler: drop out of terminal insert mode into NORMAL mode. The float stays open and
-- focused; this is just the standard "get out of insert" for a terminal buffer (mirrors <Esc> in a
-- normal buffer, minus the close). Exposed on M so tests can drive it headless with a fake instance.
function M.normal_mode_key()
  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].harness_terminal then
    vim.b[buf].harness_terminal_normal_mode = true
  end
  vim.cmd.stopinsert()
  vim.cmd("noautocmd stopinsert")
end

---The <C-f> key handler: toggle shelf mode. Turning it on animates the float out to fullscreen
-- (5% vertical / 10% horizontal padding); from then on it is fullscreen while focused and on the shelf
-- otherwise (follow_focus). Turning it off retracts the float to retract_rect. Exposed on M so tests
-- can drive it headless with a fake instance; _wide mirrors "fullscreen" for animate_collapse.
---@param self table the Snacks terminal instance (has .win, ._wide, ._saved_config)
function M.fullscreen_key(self)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if self._shelf_mode then
    self._shelf_mode = false
    self._shelved = false
    self._wide = false
    resize_to(self, retract_rect(self))
    return
  end
  save_baseline(self)
  self._shelf_mode = true
  self._shelved = false
  self._wide = true
  resize_to(self, fullscreen_rect())
end

---The shared terminal-mode key legend for EVERY harness float. This is the single home for the
-- keys shown in the float's footer - no per-harness keymap file defines or copies these; all five
-- harnesses get them from here (via win_opts), so a change to one key changes it everywhere. Each
-- entry's handler is a module-level function (close_key / normal_mode_key / go_back_key /
-- fullscreen_key / shelf_key) so tests can drive any of them headless with a fake instance. Exposed on
-- M (as M.terminal_keys) so specs can assert on the legend itself.
---@return table[] keys
function M.terminal_keys()
  return {
    {
      "<Esc>",
      function(self)
        -- Exit insert and minimize the float into its docked bar - the PTY keeps running, so it
        -- resumes from the bar or the next <leader>c. Distinct from <C-h>, which just moves focus
        -- back while leaving the panel visible.
        M.close_key(self)
      end,
      mode = "t",
      desc = "⊘",
    },

    {
      "<C-n>",
      function()
        M.normal_mode_key()
      end,
      mode = "t",
      desc = "✥",
    },
    {
      "<C-p>",
      function()
        require("util.procs").pick()
      end,
      mode = "t",
      desc = "⚙",
    },
    {
      "<C-q>",
      function()
        require("harness-decorators.switch").pick()
      end,
      mode = "t",
      desc = "⇄",
    },
    {
      "<C-h>",
      function(self)
        M.go_back_key(self)
      end,
      mode = "t",
      desc = "↩",
    },
    {
      "<C-l>",
      function(self)
        M.shelf_key(self)
      end,
      mode = "t",
      desc = "⬓",
    },
    {
      "<C-f>",
      function(self)
        M.fullscreen_key(self)
      end,
      mode = "t",
      desc = "⛶",
    },
    {
      "<C-t>",
      function()
        M.tile()
      end,
      mode = "t",
      desc = "⣿",
    },
  }
end

---The harness title with a grip glyph prepended, marking the top border as the move handle.
---@param harness string
---@return table chunks
local function grip_title(harness)
  local t = title.title(harness)
  return vim.list_extend({ { " ✥", "Special" } }, type(t) == "string" and { { t, "FloatTitle" } } or t)
end

---Build the Snacks window opts for a harness's float: position/border/title + the shared terminal
-- keys (terminal_keys). The title is harness-aware (title.title); everything else in the legend is
-- common to all harnesses and defined once in terminal_keys.
---@param harness string
---@return table win_opts
local function win_opts(harness)
  return {
    position = "float",
    -- Drag handles for the mouse move/resize below: a grip glyph in the title marks the move bar,
    -- heavy side/bottom lines mark the resizable edges, and the bottom corners are resize grips.
    -- The top-left corner is the shelf button and the top-right corner the minimize button (both
    -- double-click).
    border = {
      { "⬓", "Special" },
      "─",
      { "⊟", "Special" },
      "┃",
      { "◢", "Special" },
      "━",
      { "◣", "Special" },
      "┃",
    },
    -- Border-line caps frame the title as a tab on the top border.
    title = vim.list_extend(
      { { "┤", "FloatBorder" } },
      vim.list_extend(grip_title(harness), { { "├", "FloatBorder" } })
    ),
    b = { harness_terminal = harness },
    -- Snacks' style default maps FloatTitle:SnacksTitle, which overrides the per-segment groups in
    -- `title`. Set winhighlight after all merging is done so our override sticks.
    on_win = function(self)
      pcall(vim.api.nvim_set_option_value, "winhighlight", "FloatFooter:SnacksFooter", { win = self.win })
    end,
    -- <C-h> and <C-l> are plain movement and stay mapped without a legend entry.
    footer_keys = vim.tbl_filter(
      function(k)
        return k ~= "<C-h>" and k ~= "<C-l>"
      end,
      vim.tbl_map(function(k)
        return k[1]
      end, M.terminal_keys())
    ),
    -- fix_buf disabled (same reason as before): its BufWinEnter swap duplicates buffers during the
    -- float's destroy/recreate. Every key here manages focus explicitly, so nothing relies on it.
    fix_buf = false,
    resize = true,
    stack = true,

    keys = M.terminal_keys(),

    row = FLOAT_ROW,
    col = function()
      if zen_active() then
        return zen_float_span().col
      end
      return default_float_col()
    end,
    width = function()
      return zen_active() and zen_float_span().width or FLOAT_WIDTH
    end,
    height = function()
      return zen_active() and ZEN_HEIGHT or FLOAT_HEIGHT
    end,
  }
end

local BAR_ANIM_MS = 300

---Animate a bar from its current position/size to `to` ({ row, col, width, height }), snapping to
-- `to` on the last frame and then calling on_done. An animation already running on the same bar is
-- stopped first, so the new one starts from wherever the bar is now. Without animation.nvim it snaps
-- immediately.
---@param inst table the Snacks terminal instance that owns the bar
---@param win integer the bar window
---@param to { row: integer, col: integer, width: integer, height: integer }
---@param on_done? fun()
local function animate_win(inst, win, to, on_done)
  if inst._bar_anim then
    inst._bar_anim:finish()
    inst._bar_anim = nil
  end
  local function set(cfg)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_config, win, vim.tbl_extend("force", { relative = "editor" }, cfg))
    end
  end
  local ok_anim, Animation = pcall(require, "animation")
  if not ok_anim then
    set(to)
    if on_done then
      on_done()
    end
    return
  end
  local cur = vim.api.nvim_win_get_config(win)
  local from = { row = math.floor(cur.row), col = math.floor(cur.col), width = cur.width, height = cur.height }
  local finished = false
  inst._bar_anim = Animation(BAR_ANIM_MS, 60, require("animation.easing").in_out_sine, function(f)
    if not vim.api.nvim_win_is_valid(win) then
      return true
    end
    if f >= 1 then
      if not finished then
        finished = true
        set(to)
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
  inst._bar_anim:run()
end

---True when zen mode is currently open. M._zen_active_override lets specs force the value.
zen_active = function()
  if M._zen_active_override ~= nil then
    return M._zen_active_override
  end
  local ok, zen = pcall(require, "zen-mode.view")
  return ok and zen.is_open and zen.is_open() and true or false
end

---Minimized bars dock in the top-right corner of the editor and stack downward: slot 1 sits at the
-- top (below the tabline when one is shown), slot 2 below it, and so on. A bar the user drags away
-- leaves the dock (its _bar_slot is cleared).
---@param slot integer
---@return integer row
local function dock_row(slot)
  local stal = vim.o.showtabline
  local top = (stal == 2 or (stal == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
  return top + BAR_HEIGHT * (slot - 1)
end

---The column a docked bar whose text is `width` columns wide starts at, so its right border sits on
-- the editor's last column.
---@param width integer
---@return integer col
local function dock_col(width)
  local edge = vim.o.columns - width - 2
  if zen_active() then
    -- Just right of the rightmost visible harness float, by where it is headed (inst.opts, set by
    -- resize_to) or else where it is drawn.
    local span = zen_float_span()
    local right = span.col + span.width + 2
    for _, e in pairs(state.table) do
      local i = e.inst
      local bar = i and i._pill_win and vim.api.nvim_win_is_valid(i._pill_win)
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
local function free_slot()
  local used = {}
  for _, e in pairs(state.table) do
    local i = e.inst
    if i and i._bar_slot and i._pill_win and vim.api.nvim_win_is_valid(i._pill_win) then
      used[i._bar_slot] = true
    end
  end
  local slot = 1
  while used[slot] do
    slot = slot + 1
  end
  return slot
end

---Close the gaps in the dock: renumber the docked bars from the bottom in their current order and
-- animate any bar whose slot changed (or whose row is stale after an editor resize) into place.
local function repack_dock()
  local docked = {}
  for _, e in pairs(state.table) do
    local i = e.inst
    if i and i._bar_slot and i._pill_win and vim.api.nvim_win_is_valid(i._pill_win) then
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
    local col = dock_col(i._bar_width)
    if math.floor(cfg.row) ~= dock_row(slot) or math.floor(cfg.col) ~= col or cfg.width ~= i._bar_width then
      animate_win(i, i._pill_win, { row = dock_row(slot), col = col, width = i._bar_width, height = 1 })
    end
  end
end

vim.api.nvim_create_autocmd("VimResized", {
  group = auto_insert_group,
  callback = function()
    vim.schedule(function()
      repack_dock()
      -- zen-mode re-lays out its window in its own VimResized handler; re-place the floats after it.
      if zen_active() then
        M.set_zen_width(true)
      end
    end)
  end,
})

---Close the one-line minimized bar for this instance, if it has one.
---@param inst table the Snacks terminal instance
local function close_pill(inst)
  if inst._bar_anim then
    inst._bar_anim:finish()
    inst._bar_anim = nil
  end
  if inst._pill_win and vim.api.nvim_win_is_valid(inst._pill_win) then
    pcall(vim.api.nvim_win_close, inst._pill_win, true)
  end
  inst._pill_win = nil
  if inst._bar_slot then
    inst._bar_slot = nil
    repack_dock()
  end
end

local flash_ns = vim.api.nvim_create_namespace("harness_flash")

---Blink the float's border (or its minimized bar) a few times with HarnessFlash. The border blinks
-- through winhighlight; the bar's text carries its own per-chunk highlights, so it also gets a
-- higher-priority extmark over the whole line. Overlapping calls are dropped, and the
-- window is put back as it was after the last blink.
---@param inst table the Snacks terminal instance
local function flash(inst)
  local pill = inst._pill_win and vim.api.nvim_win_is_valid(inst._pill_win) and inst._pill_win
  local win = pill or (inst.win and vim.api.nvim_win_is_valid(inst.win) and inst.win)
  if not win or inst._flashing then
    return
  end
  vim.api.nvim_set_hl(0, "HarnessFlash", { default = true, link = "IncSearch" })
  inst._flashing = true
  local buf = vim.api.nvim_win_get_buf(win)
  local base = vim.wo[win].winhighlight
  local on = (base ~= "" and base .. "," or "") .. "FloatBorder:HarnessFlash"
  local function set(lit)
    vim.api.nvim_set_option_value("winhighlight", lit and on or base, { win = win })
    if pill then
      vim.api.nvim_buf_clear_namespace(buf, flash_ns, 0, -1)
      if lit then
        local len = #(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
        vim.api.nvim_buf_set_extmark(buf, flash_ns, 0, 0, { end_col = len, hl_group = "HarnessFlash", priority = 200 })
      end
    end
  end
  local steps = 6
  local function step()
    if not vim.api.nvim_win_is_valid(win) or steps == 0 then
      pcall(set, false)
      inst._flashing = false
      return
    end
    pcall(set, steps % 2 == 0)
    steps = steps - 1
    vim.defer_fn(step, 150)
  end
  step()
end

-- How long the terminal must stay quiet before the flash fires. On M so specs can shorten it.
M.flash_quiet_ms = 1500

local BOUNCE_ROWS, BOUNCE_MS = 2, 400

---Bounce a shelved float: lift it BOUNCE_ROWS rows and drop it back. Only the row moves, so the
-- terminal is not resized. Skipped while a bounce or resize animation is running.
---@param inst table the Snacks terminal instance
local function bounce(inst)
  local win = inst.win
  local ok_anim, Animation = pcall(require, "animation")
  if not ok_anim or inst._bouncing or (inst._resize_anim and inst._resize_anim:is_running()) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(win)
  local row, col = math.floor(cfg.row), math.floor(cfg.col)
  inst._bouncing = true
  Animation(BOUNCE_MS, 60, function(r)
    return r
  end, function(f)
    if not vim.api.nvim_win_is_valid(win) then
      inst._bouncing = false
      return true
    end
    local lift = f >= 1 and 0 or math.floor(BOUNCE_ROWS * math.sin(math.pi * f) + 0.5)
    pcall(vim.api.nvim_win_set_config, win, { relative = "editor", row = row - lift, col = col })
    if f >= 1 then
      inst._bouncing = false
    end
  end):run()
end

---Tell the user an unfocused harness has new output: a shelved float bounces, anything else (an open
-- float or a minimized bar) flashes.
---@param inst table the Snacks terminal instance
local function notify_output(inst)
  local bar = inst._pill_win and vim.api.nvim_win_is_valid(inst._pill_win)
  if inst._shelved and not bar and inst.win and vim.api.nvim_win_is_valid(inst.win) then
    bounce(inst)
  else
    flash(inst)
  end
end

-- Defined with the shelf functions below; M.open (above them) attaches it to each new float.
local follow_focus

---Signal the panel (notify_output) when its terminal gets new text while the panel is unfocused or
-- minimized. The signal fires once the output has been quiet for M.flash_quiet_ms, so a streaming
-- reply signals once when it finishes rather than on every redraw. Terminal reflow right after a
-- resize is ignored.
---@param inst table the Snacks terminal instance
local function watch_output(inst)
  if not (inst and inst.buf and vim.api.nvim_buf_is_valid(inst.buf)) or inst._flash_timer then
    return
  end
  inst._flash_timer = vim.uv.new_timer()
  vim.api.nvim_buf_attach(inst.buf, false, {
    on_lines = function()
      local focused = inst.win and vim.api.nvim_get_current_win() == inst.win
      -- An unfocused float tails its output; the focused one stays where the user scrolled.
      if not focused and not inst._tail_pending then
        inst._tail_pending = true
        vim.schedule(function()
          inst._tail_pending = false
          if inst.win and vim.api.nvim_get_current_win() ~= inst.win then
            scroll_to_bottom(inst)
          end
        end)
      end
      if focused or vim.uv.now() - (inst._resized_at or 0) < 500 then
        return
      end
      inst._flash_timer:start(
        M.flash_quiet_ms,
        0,
        vim.schedule_wrap(function()
          notify_output(inst)
        end)
      )
    end,
    on_detach = function()
      inst._flash_timer:close()
    end,
  })
end

---Bring the given instance's float to the front and move focus onto it. This is what "show / refocus"
-- means for a live terminal, and it has to handle two distinct states:
--   * window still open (the common case after <C-h>, which leaves the panel visible but moves focus
--     back to the work buffer) -> use :focus(), which does nvim_set_current_win. We must NOT use
--     :show() here: when the window already exists, Snacks' show() takes an early-return path
--     (self:update()) that re-applies the window config WITHOUT moving focus, so <leader>c after a
--     <C-h> would do nothing - the exact "it doesn't refocus" bug.
--   * window closed but buffer alive (after :hide(), i.e. parked) -> use :show() to reopen it.
---@param inst table the Snacks terminal instance (has .win, :focus(), :show())
local function show_instance(inst)
  close_pill(inst)
  for harness, e in pairs(state.table) do
    if e.inst == inst then
      mark_harness_buffer(harness, inst)
      break
    end
  end
  local win = inst.win
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      inst:focus()
    end)
  else
    pcall(function()
      inst:show()
    end)
  end
  schedule_enter_terminal_mode(inst.win, inst.buf)
end

---Show / refocus the given instance (see show_instance). A minimized one first animates its bar back
-- out to the float's size and spot (the reverse of minimize), then the float opens in its place. The
-- terminal window itself is never resized, so the harness does not redraw at every frame.
---@param inst table the Snacks terminal instance
local function focus_instance(inst)
  local bar = inst._pill_win
  if bar and vim.api.nvim_win_is_valid(bar) and inst._restore_rect then
    animate_win(inst, bar, inst._restore_rect, function()
      -- The bar may have been closed (or reused) while it was growing.
      if inst._pill_win == bar then
        show_instance(inst)
      end
    end)
    return
  end
  show_instance(inst)
end

-- True after the active harness's process exited and session following was stopped for it; the next
-- fresh start of that harness restarts following.
local follow_paused = false

---Tie session following (the JSONL watcher) to the active harness's process. When it exits (close
-- button, /exit, crash) the watcher stops and forgets its pinned session, so it does not go on to
-- pin some other session in the same project ("<harness> session detected"). A later fresh start of
-- that harness restarts the watcher for the new session.
---@param harness string
---@param inst table the Snacks terminal instance just spawned
local function follow_lifecycle(harness, inst)
  local ok, watcher = pcall(require, "harness-decorators.watcher")
  if not ok then
    return
  end
  local function active()
    return require("harness-decorators.utils").harness == harness
  end
  if follow_paused and active() then
    follow_paused = false
    watcher.reset_pin_state()
    watcher.start()
  end
  if not (inst.buf and vim.api.nvim_buf_is_valid(inst.buf)) then
    return
  end
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = inst.buf,
    once = true,
    callback = function()
      if active() then
        watcher.stop()
        watcher.reset_pin_state()
        follow_paused = true
      end
    end,
  })
end

---Open (or focus, if already open) the given harness's floating terminal. If the harness has a live
---instance (valid buffer) it is re-shown - the SAME running process resumes. Otherwise a fresh one
---is spawned with the harness's command (+ optional extra args, e.g. `--continue`).
---Returns the snacks.terminal instance.
---@param harness string
---@param opts? { args?: string } Extra CLI args appended to the spawn command (e.g. "--continue").
---@return table? instance nil if Snacks is unavailable or the harness has no command
function M.open(harness, opts)
  local existing = entry(harness).inst
  if is_live(existing) then
    focus_instance(existing)
    return existing
  end

  local ok_snacks, snacks = pcall(require, "snacks.terminal")
  if not ok_snacks or not snacks.open then
    vim.notify("harness: snacks.nvim terminal unavailable", vim.log.levels.ERROR)
    return nil
  end
  local cmd = resolve_cmd(harness)
  if not cmd then
    vim.notify("harness: no command for " .. harness, vim.log.levels.ERROR)
    return nil
  end
  if opts and opts.args then
    cmd = cmd .. " " .. opts.args
  end

  -- Spawn in the cwd of the file being edited, so `--continue` resumes THAT project's
  -- session, not the global getcwd()'s. Falls back to getcwd() for an unnamed/scratch
  -- buffer (no directory to infer).
  local spawn_cwd = vim.fn.getcwd()
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_file = vim.api.nvim_buf_get_name(cur_buf)
  if cur_file ~= "" and vim.uv.fs_stat(cur_file) then
    spawn_cwd = vim.fn.fnamemodify(cur_file, ":h")
  end
  local inst = snacks.open(cmd, {
    auto_insert = false,
    start_insert = false,
    win = win_opts(harness),
  })
  local e = entry(harness)
  e.inst = inst
  mark_harness_buffer(harness, inst)
  watch_output(inst)
  follow_focus(inst)
  follow_lifecycle(harness, inst)
  schedule_enter_terminal_mode(inst.win, inst.buf)
  e.cwd = spawn_cwd
  -- Wall-clock open time for THIS instance. The cwd-keyed label adapters (maki/pi) match the live
  -- session to this timestamp instead of assuming "newest file = current session" - which is wrong
  -- the moment you start a fresh session in a dir that already has older ones. A re-show (live
  -- branch above) deliberately does NOT touch it: the process is the same, so its open time stands.
  e.opened_at = os.time()
  return inst
end

for harness, e in pairs(state.table) do
  mark_harness_buffer(harness, e.inst)
end

-- Mouse drag on a harness float's border: the top border (the title bar) moves the float, and the
-- left, right and bottom borders resize it from that edge (bottom corners resize both ways). The
-- mappings are global expr maps because the click can come from any window/mode; anything that is
-- not a border drag is passed through unchanged. Requires 'mouse' to include n/t (see <leader>M).
local drag = nil
local MIN_WIDTH, MIN_HEIGHT = 20, 5

---The 0-based screen row/col of a float's outer top-left corner (border included) as drawn.
-- Neovim shifts a float that would not fit back onto the screen, so after an editor resize or a
-- restore near the edge the drawn spot can differ from the row/col in its config.
---@return integer row
---@return integer col
local function drawn_pos(win)
  local pos = vim.api.nvim_win_get_position(win)
  return pos[1], pos[2]
end

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
    if is_live(inst) and inst.win and vim.api.nvim_win_is_valid(inst.win) then
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
  if not drag.wide then
    inst._saved_config = nil
  end
  inst._wide = false
end

---Show the end of the terminal (the prompt) in the float's window. A float focused in terminal mode
-- already follows the terminal cursor.
---@param inst table the Snacks terminal instance
scroll_to_bottom = function(inst)
  local win = inst.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if vim.api.nvim_get_current_win() == win and vim.fn.mode() == "t" then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(inst.buf), 0 })
end

---Shelve the float: animate it out to fullscreen, then shrink it to the shelf (the bottom
-- M.shelf_rows rows of the fullscreen rect, scrolled to the end), so the harness slides down out of
-- view and leaves only its prompt showing. The pre-shelf geometry is saved as the <C-f> retract
-- target. While shelved, new output bounces the shelf instead of flashing it (notify_output).
---@param inst table the Snacks terminal instance
shelve = function(inst)
  if not (inst.win and vim.api.nvim_win_is_valid(inst.win)) then
    return
  end
  save_baseline(inst)
  inst._shelved = true
  inst._wide = false
  local function slide_up()
    if inst._shelved then
      resize_to(inst, shelf_rect(), function()
        scroll_to_bottom(inst)
      end)
    end
  end
  if at_rect(inst.win, fullscreen_rect()) then
    slide_up()
  else
    resize_to(inst, fullscreen_rect(), slide_up)
  end
end

---Unshelve the float: animate it back to fullscreen, the same state as a <C-f> fullscreen.
---@param inst table the Snacks terminal instance
local function unshelve(inst)
  if not (inst.win and vim.api.nvim_win_is_valid(inst.win)) then
    return
  end
  inst._shelved = false
  inst._wide = true
  resize_to(inst, fullscreen_rect())
end

---<C-l>: with shelf mode on and the float focused at fullscreen inside tmux, move to the tmux pane on
-- the right (the float keeps nvim focus and stays fullscreen); otherwise in shelf mode, nothing. With
-- shelf mode off, go back the way <C-h> does.
---@param self table the Snacks terminal instance
function M.shelf_key(self)
  if self._shelf_mode then
    shelf_tmux_nav(self, "R")
    return
  end
  go_back(self)
end

---Double-clicking the shelf button: turn shelf mode on and shelve the float right away (moving focus
-- back if the float had it), or turn it off and grow the float back to fullscreen.
---@param inst table the Snacks terminal instance
function M.shelf_button(inst)
  if inst._shelf_mode then
    inst._shelf_mode = false
    unshelve(inst)
    return
  end
  inst._shelf_mode = true
  shelve(inst)
  if inst.win and vim.api.nvim_get_current_win() == inst.win then
    go_back(inst)
  end
end

---Drive shelf mode from focus: entering the float unshelves it, leaving it shelves it again. Both
-- run on the next tick so the window switch has settled (WinLeave fires while the float is still
-- current, and minimize hides the window after turning shelf mode off).
---@param inst table the Snacks terminal instance
follow_focus = function(inst)
  if not (inst and inst.buf and vim.api.nvim_buf_is_valid(inst.buf)) then
    return
  end
  local function shown()
    local bar = inst._pill_win and vim.api.nvim_win_is_valid(inst._pill_win)
    return inst._shelf_mode and not bar and inst.win and vim.api.nvim_win_is_valid(inst.win)
  end
  vim.api.nvim_create_autocmd("WinEnter", {
    buffer = inst.buf,
    callback = function()
      vim.schedule(function()
        if
          shown()
          and vim.api.nvim_get_current_win() == inst.win
          and (inst._shelved or not at_rect(inst.win, fullscreen_rect()))
        then
          unshelve(inst)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = inst.buf,
    callback = function()
      vim.schedule(function()
        if shown() and not inst._shelved and vim.api.nvim_get_current_win() ~= inst.win then
          shelve(inst)
        end
      end)
    end,
  })
  -- The key legend (Snacks' footer) shows only while the float has focus.
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    buffer = inst.buf,
    callback = function()
      vim.schedule(function()
        local win = inst.win
        if not (win and vim.api.nvim_win_is_valid(win)) then
          return
        end
        local footer = vim.api.nvim_win_get_config(win).footer
        local has = type(footer) == "table" and #footer > 0 or (type(footer) == "string" and footer ~= "")
        if vim.api.nvim_get_current_win() == win then
          if not has and inst._footer then
            pcall(vim.api.nvim_win_set_config, win, { footer = inst._footer, footer_pos = "center" })
          end
        elseif has then
          inst._footer = footer
          pcall(vim.api.nvim_win_set_config, win, { footer = "" })
        end
      end)
    end,
  })
  -- Zen mode with shelf mode off: the float steps aside into the gap right of zen while another
  -- window has focus and grows back to the zen spot when it gets focus.
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    buffer = inst.buf,
    callback = function()
      vim.schedule(function()
        if M._tiled then
          retile()
          return
        end
        local bar = inst._pill_win and vim.api.nvim_win_is_valid(inst._pill_win)
        if bar or inst._shelf_mode or not zen_active() or not (inst.win and vim.api.nvim_win_is_valid(inst.win)) then
          return
        end
        local rect = auto_float_rect(inst.win)
        if not at_rect(inst.win, rect) then
          resize_to(inst, rect)
          repack_dock()
        end
      end)
    end,
  })
end

---Minimize the float: hide its window (the PTY keeps running, same as <Esc>) and put a one-line bar
-- with the harness title in the top-right dock. The bar opens at the float's size and position and
-- animates down into its dock slot; the terminal window itself is never resized, so the harness does
-- not redraw at every frame. Double-clicking the bar (see
-- restore_from_bar), <leader>c or a re-pick restores it through focus_instance, which closes the bar.
-- Clicking the bar's close icon ends the harness (see close_harness); clicking its restore icon
-- restores it (see bar_button).
---@param inst table the Snacks terminal instance
minimize_float = function(inst)
  local harness
  for h, e in pairs(state.table) do
    if e.inst == inst then
      harness = h
    end
  end
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
  if inst._shelf_mode or inst._shelved or inst._wide then
    local r = auto_float_rect()
    inst._restore_rect = vim.deepcopy(r)
    inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = r.row, r.col, r.width, r.height
  end
  inst._shelf_mode, inst._shelved, inst._wide, inst._saved_config = false, false, false, nil
  inst._bar_slot = free_slot()
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
  animate_win(
    inst,
    inst._pill_win,
    { row = dock_row(inst._bar_slot), col = dock_col(width), width = width, height = 1 }
  )
end

---The instance whose minimized bar (border included) contains the given 1-based screen pos, and
-- that bar's window.
---@return table? inst
---@return integer? bar
local function bar_hit(screenrow, screencol)
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

---Restore a minimized harness the same way picking it in <C-q> would: the switch rebinds
-- keymaps/watcher to this harness and shows it. Other open floats stay open.
---@param inst table the Snacks terminal instance
local function restore_from_bar(inst)
  local harness
  for h, e in pairs(state.table) do
    if e.inst == inst then
      harness = h
    end
  end
  if not harness then
    focus_instance(inst)
    return
  end
  require("harness-decorators.switch").switch(harness)
  require("harness-decorators.park").set_selected(harness)
  require("harness-decorators.park").show_selected()
end

---Minimize the given harness's float into its bar. Returns false when the harness has no open
-- float to minimize (never opened, closed with <Esc>, or already minimized).
---@param harness string
---@return boolean minimized
function M.minimize(harness)
  local inst = entry(harness).inst
  if not (is_live(inst) and inst.win and vim.api.nvim_win_is_valid(inst.win)) then
    return false
  end
  minimize_float(inst)
  return true
end

---Drop shelf mode and fullscreen and point the float back at its normal spot (the zen spot while zen
-- is open). Open floats move there; minimized ones restore there. With `harness`, only that harness
-- is reset and tiling stays on (re-tiling if active); without it, every harness is reset and tiling
-- ends.
---@param harness? string
function M.reset_layout(harness)
  if not harness then
    M._tiled = false
  end
  local rect = auto_float_rect()
  for h, e in pairs(state.table) do
    local inst = e.inst
    if inst and (not harness or h == harness) then
      inst._shelf_mode, inst._shelved, inst._wide, inst._saved_config = false, false, false, nil
      inst.opts = inst.opts or {}
      inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = rect.row, rect.col, rect.width, rect.height
      if inst._pill_win and vim.api.nvim_win_is_valid(inst._pill_win) then
        inst._restore_rect = vim.deepcopy(rect)
      elseif inst.win and vim.api.nvim_win_is_valid(inst.win) and not M._tiled then
        resize_to(inst, rect)
      end
    end
  end
  if M._tiled then
    retile()
  end
end

---Animate all open harness floats to their spot when zen mode opens or closes. In shelf mode the
-- focused float goes fullscreen and any other goes to the shelf. Otherwise the float takes the zen
-- spot (narrow) or returns to the default spot. Called from the zen-mode on_open/on_close and on an
-- editor resize while zen is open.
---@param narrow boolean
function M.set_zen_width(narrow)
  local base = default_float_rect()
  for _, e in pairs(state.table) do
    local inst = e.inst
    if inst and inst.win and vim.api.nvim_win_is_valid(inst.win) and inst._shelf_mode then
      local focused = vim.api.nvim_get_current_win() == inst.win
      local rect = focused and fullscreen_rect() or shelf_rect()
      inst._shelved = not focused
      inst._wide = focused
      resize_to(inst, rect, function()
        if not focused then
          scroll_to_bottom(inst)
        end
      end)
    elseif not M._tiled and inst and inst.win and vim.api.nvim_win_is_valid(inst.win) then
      local rect = vim.deepcopy(base)
      if narrow then
        local span = vim.api.nvim_get_current_win() == inst.win and zen_float_span() or zen_side_span()
        rect.col, rect.width = span.col, span.width
        rect.height = math.floor(vim.o.lines * ZEN_HEIGHT) - 2
      end
      resize_to(inst, rect)
      if not narrow then
        -- Fractions, so Snacks re-derives the default size after an editor resize.
        inst.opts.width, inst.opts.height = FLOAT_WIDTH, FLOAT_HEIGHT
      end
    end
  end
  if M._tiled then
    retile()
  end
  repack_dock()
end

---The floats tiling arranges: shown (not minimized) and outside shelf mode, sorted by harness name.
---@return table[] insts
local function tile_members()
  local list = {}
  for h, e in pairs(state.table) do
    local i = e.inst
    local bar = i and i._pill_win and vim.api.nvim_win_is_valid(i._pill_win)
    if i and not bar and not i._shelf_mode and i.win and vim.api.nvim_win_is_valid(i.win) then
      table.insert(list, { harness = h, inst = i })
    end
  end
  table.sort(list, function(a, b)
    return a.harness < b.harness
  end)
  return vim.tbl_map(function(m)
    return m.inst
  end, list)
end

---`n` rects in a grid `outer_width` wide (border included) starting at `col`, filled row by row,
-- over the default float height: one per row up to 3, then 2 per row, then 3, so there are at most 3
-- rows. Rows and columns split the space evenly; the last row/column takes the remainder. Cells
-- that have a neighbour to their right or below give up one column or row as a gap.
---@return { row: integer, col: integer, width: integer, height: integer }[]
local function stack_rects(n, col, outer_width)
  local total = math.floor(vim.o.lines * FLOAT_HEIGHT)
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

---Lay the open harness floats out in the grid. The focused float (else the one focused last, if
-- still open) takes its normal spot; the others fill the grid left of the zen window while zen is
-- open, else at the far right before the dock's reserved space, with the focused float just left of
-- the grid. With `cycle`, when the focused float and the grid are already in place, focus moves to
-- the next float by harness name instead (the focus change re-tiles).
---@param cycle? boolean
retile = function(cycle)
  local members = tile_members()
  if #members == 0 then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  local focused
  for _, i in ipairs(members) do
    if i.win == cur then
      focused = i
    end
  end
  local current = focused
  -- A switch is moving focus to M._focus_target (see M.expect_focus). Until it lands, that harness
  -- counts as focused (or, when it is not open yet, nothing does), so the float losing focus goes
  -- straight into the grid instead of stepping aside first.
  local pending = false
  if M._focus_target then
    local e = state.table[M._focus_target]
    local target = e and e.inst
    if target and target.win == cur then
      M._focus_target = nil
    else
      pending = true
      M._tile_focus = target
      focused = vim.tbl_contains(members, target) and target or nil
    end
  end
  if focused then
    M._tile_focus = focused
  elseif vim.tbl_contains(members, M._tile_focus) then
    focused = M._tile_focus
  end
  local others = vim.tbl_filter(function(i)
    return i ~= focused
  end, members)

  local focus_rect, stack
  local ok, zen = pcall(require, "zen-mode.view")
  local zwin = ok and zen.is_open and zen.is_open() and zen.win
  if zwin and vim.api.nvim_win_is_valid(zwin) then
    -- The zen spot while focused, the gap right of zen while another window has focus.
    focus_rect = focused and auto_float_rect(not pending and focused.win or nil)
    local zleft = math.floor(vim.api.nvim_win_get_config(zwin).col)
    local empty = math.max(3, zleft - 1)
    -- A cell is at most half the empty area, so a single column hugs zen.
    local width = #others <= 3 and math.max(3, math.floor(empty / 2)) or empty
    stack = stack_rects(#others, empty - width, width)
    if focused and focused.win ~= cur and not pending then
      -- Stepped aside (focus elsewhere): a grid cell's width at the grid's full height, just right
      -- of zen. The dock moves right of it (dock_col).
      local cell = stack[1] or stack_rects(1, 0, width)[1]
      local tall = math.floor(vim.o.lines * FLOAT_HEIGHT) - 2
      focus_rect = { row = 0, col = zen_side_span().col, width = cell.width, height = tall }
    end
  else
    focus_rect = default_float_rect()
    if #others > 0 then
      local cols = vim.o.columns
      local width = math.floor(cols * ZEN_MIN_WIDTH)
      local col = math.max(0, cols - (BAR_MIN_TEXT + 2) - 1 - width)
      stack = stack_rects(#others, col, width)
      focus_rect.col = math.max(0, col - 1 - (focus_rect.width + 2))
    end
  end

  local in_place = focused ~= nil and at_rect(focused.win, focus_rect)
  for k, i in ipairs(others) do
    in_place = in_place and at_rect(i.win, stack[k])
  end
  if cycle and in_place and current and #members > 1 then
    for k, i in ipairs(members) do
      if i == current then
        -- The cycled-to float becomes the active harness, the same as picking it in <C-q>.
        local nxt = members[k % #members + 1]
        for h, e in pairs(state.table) do
          if e.inst == nxt then
            pcall(require("harness-decorators.switch").switch, h)
          end
        end
        focus_instance(nxt)
        return
      end
    end
  end

  if focused and not at_rect(focused.win, focus_rect) then
    resize_to(focused, focus_rect)
  end
  for k, i in ipairs(others) do
    if not at_rect(i.win, stack[k]) then
      resize_to(i, stack[k])
    end
  end
  repack_dock()
end

---Mark `harness` as about to get focus (a <C-q> pick or <C-t> cycle). Re-tiles before its focus
-- lands treat it as the focused float; the mark clears once focus lands or after a second.
---@param harness string
function M.expect_focus(harness)
  M._focus_target = harness
  vim.defer_fn(function()
    if M._focus_target == harness then
      M._focus_target = nil
    end
  end, 1000)
end

---The <C-t> key: turn tiling on (focus changes and zen open/close keep re-tiling until
-- reset_layout) and lay the floats out in the grid; once everything is already in place, cycle focus
-- to the next float instead.
function M.tile()
  M._tiled = true
  retile(true)
end

---Turn tiling on and lay the floats out in the grid, without the <C-t> focus cycling. Used after a
-- <C-q> pick.
function M.grid()
  M._tiled = true
  retile()
end

---Which of a minimized bar's buttons the given 1-based screen column hits: "restore" for the restore
-- icon and the cell on either side of it, "close" for the close icon, the cell on either side of it
-- and the bar's right border, nil anywhere else.
---@return "restore"|"close"|nil
local function bar_button(inst, bar, screencol)
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

---Close a minimized harness: remove its bar and send SIGTERM to the process in its terminal. Snacks
-- keeps a terminal buffer open after a non-zero exit (SIGTERM exits with 143), so the buffer is wiped
-- here once the process has exited; park.list then drops the harness and the next <leader>c or <C-q>
-- pick starts a fresh session.
---@param inst table the Snacks terminal instance
local function close_harness(inst)
  close_pill(inst)
  local buf = inst.buf
  local chan = buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].channel or 0
  if chan > 0 then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end)
      end,
    })
    local ok, pid = pcall(vim.fn.jobpid, chan)
    if ok and pid and pid > 0 then
      vim.uv.kill(pid, "sigterm")
    end
  end
end

---Mouse handlers for the harness floats and their minimized bars. Each takes a getmousepos()-shaped
-- position and returns the keys the mapping should produce: "" when the event was handled here, or
-- the original mouse key to pass it through. The mappings below call these with vim.fn.getmousepos();
-- specs call them directly with made-up positions, since headless Neovim gets no real mouse input.
M.mouse = {}

-- True from a press these handlers consumed until its release. The drag and release events of that
-- click are swallowed too: passed through, Neovim would move the cursor to the window under the
-- mouse, which after a restore or close is the editor window the bar was floating over.
local press_consumed = false

---@param mouse { screenrow: integer, screencol: integer }
---@return string keys
function M.mouse.press(mouse)
  press_consumed = true
  local minimized, bar = bar_hit(mouse.screenrow, mouse.screencol)
  local button = minimized and bar_button(minimized, bar, mouse.screencol)
  if button then
    drag = nil
    vim.schedule(function()
      if button == "close" then
        close_harness(minimized)
      else
        restore_from_bar(minimized)
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
    wide = inst._wide,
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
function M.mouse.drag(mouse)
  if not drag then
    return press_consumed and "" or "<LeftDrag>"
  end
  vim.schedule(function()
    drag_to(mouse)
  end)
  return ""
end

---@return string keys
function M.mouse.release()
  local consumed = press_consumed or drag ~= nil
  press_consumed = false
  drag = nil
  return consumed and "" or "<LeftRelease>"
end

---@param mouse { screenrow: integer, screencol: integer }
---@return string keys
function M.mouse.double(mouse)
  local minimized, bar = bar_hit(mouse.screenrow, mouse.screencol)
  if minimized then
    press_consumed = true
    -- The buttons already fired on the first click of the double-click.
    if not bar_button(minimized, bar, mouse.screencol) then
      vim.schedule(function()
        restore_from_bar(minimized)
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
          M.shelf_button(inst)
        end
      end)
      return ""
    end
  end
  return "<2-LeftMouse>"
end

local drag_modes = { "n", "t" }
local drag_desc = "Move/resize harness float by its border"
vim.keymap.set(drag_modes, "<LeftMouse>", function()
  return M.mouse.press(vim.fn.getmousepos())
end, { expr = true, desc = drag_desc })
vim.keymap.set(drag_modes, "<LeftDrag>", function()
  return M.mouse.drag(vim.fn.getmousepos())
end, { expr = true, desc = drag_desc })
vim.keymap.set(drag_modes, "<LeftRelease>", function()
  return M.mouse.release()
end, { expr = true, desc = drag_desc })
vim.keymap.set(drag_modes, "<2-LeftMouse>", function()
  return M.mouse.double(vim.fn.getmousepos())
end, { expr = true, desc = "Minimize/restore harness float" })

---Wall-clock unix time the given harness's CURRENT terminal instance was opened, or nil when it has
--no live instance. Used by cwd-keyed label adapters to pick the session that matches this open rather
--than the most recently active one for the dir.
---@param harness string
---@return number?
function M.opened_at(harness)
  local e = state.table[harness]
  if e and is_live(e.inst) then
    return e.opened_at
  end
  return nil
end

---@param harness string
---@return string?
function M.cwd(harness)
  local e = state.table[harness]
  if e and is_live(e.inst) then
    return e.cwd
  end
  return nil
end

---The buffer number holding the given harness's terminal, or nil if it has no live instance.
---@param harness string
---@return number? bufnr
function M.bufnr(harness)
  local inst = entry(harness).inst
  if is_live(inst) then
    return inst.buf
  end
  return nil
end

---Show (un-hide / focus) the given harness's float. No-op if it has no live instance. Routes through
-- focus_instance so an already-open window is re-focused (not just re-configured) - this is what makes
-- <leader>c refocus a panel that <C-h> left visible-but-unfocused.
---@param harness string
function M.show(harness)
  local inst = entry(harness).inst
  if is_live(inst) then
    focus_instance(inst)
  end
end

---Hide the given harness's float WITHOUT killing its process. Snacks' :hide() closes only the
---window (buf=false), leaving the buffer - and therefore the PTY - alive so it keeps executing.
---This is what "parking" a harness means now: no global handle to detach, just hide this one.
---@param harness string
function M.hide(harness)
  local inst = entry(harness).inst
  if is_live(inst) then
    pcall(function()
      inst:hide()
    end)
  end
end

---True if the given harness currently has a live (valid-buffer) terminal instance.
---@param harness string
---@return boolean
function M.is_open(harness)
  local e = state.table[harness]
  return e ~= nil and is_live(e.inst)
end

---List of { harness, bufnr } for every harness with a live instance, sorted by name. Used by the
---picker previewer (via park.list) to show "what each one is doing". Entries whose instance has
---EXITED (had a buffer that died) are dropped so the picker never offers a dead process. A harness
---that was merely SELECTED but never opened (inst == nil) is NOT dropped: deleting it would wipe its
---selection bit, and then <leader>c / show_selected bails before term.open - the "<leader>c does
---nothing after opening the picker" regression. Only a genuinely-exited instance is garbage.
---@return { harness: string, bufnr: number }[]
function M.list()
  local out = {}
  local dead = {}
  for harness, e in pairs(state.table) do
    if is_live(e.inst) then
      table.insert(out, { harness = harness, bufnr = e.inst.buf })
    elseif e.inst ~= nil then
      -- Had an instance that is no longer live: the process exited. Drop it. (inst == nil means
      -- never opened - keep the record so its selection bit survives.)
      table.insert(dead, harness) -- collect; removing during pairs() is undefined
    end
  end
  for _, h in ipairs(dead) do
    state.table[h] = nil
  end
  table.sort(out, function(a, b)
    return a.harness < b.harness
  end)
  return out
end

---Test-only: clear the shared state table (instances AND selection bits) without touching any buffer.
function M._reset()
  state._reset()
  M._tiled, M._tile_focus, M._focus_target = false, nil, nil
end

return M
