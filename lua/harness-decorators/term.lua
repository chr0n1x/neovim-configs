-- Owns one Snacks floating terminal per harness, stored in state.table[harness].inst.
local M = {}

local state = require("harness-decorators.state")

local function mark_harness_buffer(harness, inst)
  if inst and inst.buf and vim.api.nvim_buf_is_valid(inst.buf) then
    vim.b[inst.buf].harness_terminal = harness
  end
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
    vim.defer_fn(function()
      enter_terminal_mode(win, buf, waited + 20)
    end, 20)
    return
  end
  if
    not vim.api.nvim_win_is_valid(win)
    or not vim.api.nvim_buf_is_valid(buf)
    or vim.api.nvim_get_current_win() ~= win
    or vim.api.nvim_win_get_buf(win) ~= buf
    or vim.bo[buf].buftype ~= "terminal"
    or not vim.b[buf].harness_terminal
    or vim.fn.mode(1) == "t"
    or vim.b[buf].harness_terminal_normal_mode
  then
    return
  end
  vim.cmd.startinsert()
end

-- Forward-declared so the functions below can close over it before its definition.
local schedule_enter_terminal_mode

local function harness_terminal_buf()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].harness_terminal then
    return buf
  end
  return nil
end

---Enter terminal mode for (win, buf) on the next tick: snacks.open and a re-focus both return before
-- the window/buffer has settled, so a synchronous startinsert does not reliably stick. The
-- WinEnter/FocusGained autocmds only fire when focus actually moves, so re-selecting a harness whose
-- float already has focus (e.g. pressing <leader>c a second time while sitting in it) never triggers
-- them; every focus/open path in this module calls this directly.
---@param win integer?
---@param buf integer?
schedule_enter_terminal_mode = function(win, buf)
  if not win or not buf then
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].harness_terminal_normal_mode = false
  end
  vim.schedule(function()
    enter_terminal_mode(win, buf)
  end)
end

---See state.entry.
---@param harness string
---@return table entry { inst = snacks.terminal|nil }
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
  local ok, env = pcall(require, "harness-decorators." .. harness .. ".env")
  if not ok or type(env) ~= "table" or type(env.command) ~= "function" or type(env.prepare_env) ~= "function" then
    return nil
  end
  return env.command(), env
end

local float_util = require("harness-decorators.float-util")
local dock = require("harness-decorators.dock")
local has_bar, repack_dock, close_pill, minimize_float =
  dock.has_bar, dock.repack_dock, dock.close_pill, dock.minimize_float
local find_base_window, grip_title = float_util.find_base_window, float_util.grip_title

local layout = require("harness-decorators.layout")
local BAR_MIN_TEXT = layout.BAR_MIN_TEXT
local FLOAT_ROW, FLOAT_WIDTH, FLOAT_HEIGHT = layout.FLOAT_ROW, layout.FLOAT_WIDTH, layout.FLOAT_HEIGHT
local ZEN_MIN_WIDTH, ZEN_HEIGHT = layout.ZEN_MIN_WIDTH, layout.ZEN_HEIGHT
local zen_active, zen_float_span, zen_side_span = layout.zen_active, layout.zen_float_span, layout.zen_side_span
local default_float_col, default_float_rect = layout.default_float_col, layout.default_float_rect
local fullscreen_rect, shelf_rect, auto_float_rect = layout.fullscreen_rect, layout.shelf_rect, layout.auto_float_rect
local retract_rect, at_rect = layout.retract_rect, layout.at_rect
local stack_rects = layout.stack_rects

-- term.shelf_rows and term._zen_active_override are spec knobs kept on M; they live in layout.
local layout_knobs = { shelf_rows = "shelf_rows", _zen_active_override = "zen_active_override" }
setmetatable(M, {
  __index = function(_, k)
    local name = layout_knobs[k]
    if name then
      return layout[name]
    end
  end,
  __newindex = function(t, k, v)
    local name = layout_knobs[k]
    if name then
      layout[name] = v
    else
      rawset(t, k, v)
    end
  end,
})

local retile -- forward declaration; defined below
local scroll_to_bottom -- forward declaration; defined below

---Animate the float to `rect` and keep that geometry in inst.opts, so Snacks reopens it there after
-- hide/show. _resized_at is stamped at both ends so the terminal's reflow for the new size is not
-- taken for new output (watch_output).
---@param inst table the Snacks terminal instance
---@param rect { row: integer, col: integer, width: integer, height: integer }
---@param on_done? fun() runs once the animation lands (not when a newer resize cuts it off)
local function resize_to(inst, rect, on_done)
  inst._resized_at = vim.uv.now()
  inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = rect.row, rect.col, rect.width, rect.height
  require("harness-decorators.terminal-animations").animate_resize(inst, rect, function()
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

---Collapse a fullscreen float back to its saved geometry, animated.
local function animate_collapse(self)
  if not (layout.get(self) == "fullscreen" and self._saved_config) then
    return
  end
  layout.set(self, "normal")
  resize_to(self, retract_rect(self))
end

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
    find_base_window()
  end
  vim.cmd.redraw()
  vim.cmd("noh")
end

---<C-h>: return to the work window, leaving the float visible and collapsed.
-- In shelf mode, the focused float slides to the shelf and focus goes back; an unfocused float
-- stays put.
---@param self table the Snacks terminal instance (has :hide(), :show())
function M.go_back_key(self)
  if self._shelf_mode then
    if self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_get_current_win() == self.win then
      shelve(self)
      go_back(self)
    end
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
  -- pcall: callable outside terminal-insert (tests).
  pcall(vim.cmd.stopinsert)
  if self._shelf_mode and self.win and vim.api.nvim_win_is_valid(self.win) then
    shelve(self)
    go_back(self)
    return
  end
  local harness = state.harness_of(self)
  if harness and M.minimize(harness) then
    return
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

---<C-n>: leave terminal-insert; the float stays open and focused.
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
-- can drive it headless with a fake instance.
---@param self table the Snacks terminal instance (has .win, ._saved_config)
function M.fullscreen_key(self)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if self._shelf_mode then
    layout.set(self, "normal", { shelf_mode = false })
    resize_to(self, retract_rect(self))
    return
  end
  save_baseline(self)
  layout.set(self, "fullscreen", { shelf_mode = true })
  resize_to(self, fullscreen_rect())
end

---Terminal-mode keys and footer legend shared by every harness float.
---@return table[] keys
function M.terminal_keys()
  return {
    {
      "<Esc>",
      function(self)
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
    -- fix_buf's BufWinEnter swap duplicates buffers when the float is recreated.
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

local flash_ns = vim.api.nvim_create_namespace("harness_flash")

---Blink the float's border (or its minimized bar) a few times with HarnessFlash. The border blinks
-- through winhighlight; the bar's text carries its own per-chunk highlights, so it also gets a
-- higher-priority extmark over the whole line. Overlapping calls are dropped, and the
-- window is put back as it was after the last blink.
---@param inst table the Snacks terminal instance
local function flash(inst)
  local pill = has_bar(inst) and inst._pill_win
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
  local bar = has_bar(inst)
  if layout.get(inst) == "shelved" and not bar and inst.win and vim.api.nvim_win_is_valid(inst.win) then
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

---:focus() when the window exists (Snacks' :show() only re-applies config and does not move
-- focus); :show() when only the buffer is alive.
---@param inst table the Snacks terminal instance (has .win, :focus(), :show())
local function show_instance(inst)
  close_pill(inst)
  local harness = state.harness_of(inst)
  if harness then
    mark_harness_buffer(harness, inst)
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
  if dock.grow_back(inst, function()
    show_instance(inst)
  end) then
    return
  end
  show_instance(inst)
end

-- Harnesses whose process exited, keyed by name. Following stays off for them (activating the dead
-- float does not restart it) until a fresh start of that harness.
local follow_paused = {}

---Whether session following is off for this harness because its process exited.
---@param harness string
---@return boolean
function M.follow_paused(harness)
  return follow_paused[harness] == true
end

---Tie session following (the JSONL watcher) to each harness's process. When it exits (close
-- button, /exit, crash) the watcher stops and forgets its pinned session if that harness is active,
-- so it does not go on to pin some other session in the same project ("<harness> session detected").
-- A later fresh start of that harness restarts the watcher for the new session.
---@param harness string
---@param inst table the Snacks terminal instance just spawned
local function follow_lifecycle(harness, inst)
  local ok, watcher = pcall(require, "harness-decorators.watcher")
  if not ok then
    return
  end
  local function active()
    return require("harness-decorators.active").get() == harness
  end
  if follow_paused[harness] then
    follow_paused[harness] = nil
    if active() then
      watcher.reset_pin_state()
      watcher.start()
    end
  end
  if not (inst.buf and vim.api.nvim_buf_is_valid(inst.buf)) then
    return
  end
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = inst.buf,
    once = true,
    callback = function()
      follow_paused[harness] = true
      if active() then
        watcher.stop()
        watcher.reset_pin_state()
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
  M.setup()
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
  local cmd, env = resolve_cmd(harness)
  if not cmd then
    vim.notify("harness: no command for " .. harness, vim.log.levels.ERROR)
    return nil
  end
  if opts and opts.args then
    cmd = cmd .. " " .. opts.args
  end

  local job_env = env.prepare_env()
  local inst = snacks.open(cmd, {
    env = next(job_env) and job_env or nil,
    auto_insert = false,
    start_insert = false,
    win = win_opts(harness),
  })
  local e = entry(harness)
  e.inst = inst
  mark_harness_buffer(harness, inst)
  watch_output(inst)
  if inst.buf and vim.api.nvim_buf_is_valid(inst.buf) then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = inst.buf,
      once = true,
      callback = function()
        close_pill(inst)
        if state.table[harness] and state.table[harness].inst == inst then
          state.table[harness] = nil
        end
      end,
    })
  end
  follow_focus(inst)
  follow_lifecycle(harness, inst)
  schedule_enter_terminal_mode(inst.win, inst.buf)
  -- Snacks spawns the job in nvim's cwd; the state adapters look up sessions under this.
  e.cwd = vim.fn.getcwd()
  -- Open time, used by cwd-keyed label adapters (utils.pick_jsonl_by_time).
  e.opened_at = os.time()
  return inst
end

for harness, e in pairs(state.table) do
  mark_harness_buffer(harness, e.inst)
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
  layout.set(inst, "shelved")
  local function slide_up()
    if layout.get(inst) == "shelved" then
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
---@param shelf_mode? boolean set shelf mode to this as well
local function unshelve(inst, shelf_mode)
  if not (inst.win and vim.api.nvim_win_is_valid(inst.win)) then
    return
  end
  layout.set(inst, "fullscreen", { shelf_mode = shelf_mode })
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
    unshelve(inst, false)
    return
  end
  shelve(inst)
  if inst.win and vim.api.nvim_get_current_win() == inst.win then
    go_back(inst)
  end
end

---Follow focus into and out of the float with one WinEnter and one WinLeave handler, each running,
-- in order: shelf mode (entering unshelves, leaving shelves), the key legend, then tiling or the zen
-- step-aside. They run on the next tick so the window switch has settled (WinLeave fires while the
-- float is still current, and minimize hides the window after turning shelf mode off).
---@param inst table the Snacks terminal instance
follow_focus = function(inst)
  if not (inst and inst.buf and vim.api.nvim_buf_is_valid(inst.buf)) then
    return
  end
  local function shown()
    local bar = has_bar(inst)
    return inst._shelf_mode and not bar and inst.win and vim.api.nvim_win_is_valid(inst.win)
  end
  -- Shelf mode: entering unshelves the float, leaving shelves it.
  local function follow_shelf(entering)
    if not shown() then
      return
    end
    local focused = vim.api.nvim_get_current_win() == inst.win
    if entering then
      if focused and (layout.get(inst) == "shelved" or not at_rect(inst.win, fullscreen_rect())) then
        unshelve(inst)
      end
    elseif layout.get(inst) ~= "shelved" and not focused then
      shelve(inst)
    end
  end
  -- The key legend (Snacks' footer) shows only while the float has focus.
  local function follow_footer()
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
  end
  -- Tiled: re-tile. Zen mode with shelf mode off: the float steps aside into the gap right of zen
  -- while another window has focus and grows back to the zen spot when it gets focus.
  local function follow_zen()
    if M._tiled then
      retile()
      return
    end
    local bar = has_bar(inst)
    if bar or inst._shelf_mode or not zen_active() or not (inst.win and vim.api.nvim_win_is_valid(inst.win)) then
      return
    end
    local rect = auto_float_rect(inst.win)
    if not at_rect(inst.win, rect) then
      resize_to(inst, rect)
      repack_dock()
    end
  end
  for event, entering in pairs({ WinEnter = true, WinLeave = false }) do
    vim.api.nvim_create_autocmd(event, {
      buffer = inst.buf,
      callback = function()
        vim.schedule(function()
          follow_shelf(entering)
          follow_footer()
          follow_zen()
        end)
      end,
    })
  end
end

---Restore a minimized harness the same way picking it in <C-q> would: the switch rebinds
-- keymaps/watcher to this harness and shows it. Other open floats stay open.
---@param inst table the Snacks terminal instance
local function restore_from_bar(inst)
  local harness = state.harness_of(inst)
  if not harness then
    focus_instance(inst)
    return
  end
  require("harness-decorators.switch").switch(harness)
  if require("harness-decorators.active").get() ~= harness then
    focus_instance(inst)
    return
  end
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

---Drop shelf mode and fullscreen for every harness and point the float back at its normal spot (the
-- zen spot while zen is open). Open floats move there; minimized ones restore there. With `harness`,
-- only that harness is moved, the others are left for the grid, and tiling stays on (re-tiling if
-- active); without it, every harness is moved and tiling ends.
---@param harness? string
function M.reset_layout(harness)
  if not harness then
    M._tiled = false
  end
  local rect = auto_float_rect()
  for h, e in pairs(state.table) do
    local inst = e.inst
    if inst then
      local minimized = layout.get(inst) == "minimized"
      layout.set(inst, minimized and "minimized" or "normal", { shelf_mode = false, forget_baseline = true })
    end
    if inst and (not harness or h == harness) then
      inst.opts = inst.opts or {}
      inst.opts.row, inst.opts.col, inst.opts.width, inst.opts.height = rect.row, rect.col, rect.width, rect.height
      if has_bar(inst) then
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
      layout.set(inst, focused and "fullscreen" or "shelved")
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
    local bar = has_bar(i)
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

---Move a tiled float to `rect` unless it is there already or its running animation, started by an
-- earlier retile, is heading there. One <C-t> cycle press retiles several times (the switch, then
-- the WinLeave and WinEnter of the focus change); the later ones find the floats mid-animation and
-- would otherwise restart the same move from the intermediate rect.
---@param inst table the Snacks terminal instance
---@param rect { row: integer, col: integer, width: integer, height: integer }
local function tile_to(inst, rect)
  if at_rect(inst.win, rect) then
    return
  end
  if inst._resize_anim and inst._resize_anim == inst._tile_anim and vim.deep_equal(inst._tile_rect, rect) then
    return
  end
  inst._tile_rect = vim.deepcopy(rect)
  resize_to(inst, rect, function()
    inst._tile_rect = nil
  end)
  inst._tile_anim = inst._resize_anim
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
  local zwin = require("util.zen").win()
  if zwin then
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
        local h = state.harness_of(nxt)
        if h then
          pcall(require("harness-decorators.switch").switch, h)
        end
        focus_instance(nxt)
        return
      end
    end
  end

  if focused then
    tile_to(focused, focus_rect)
  end
  for k, i in ipairs(others) do
    tile_to(i, stack[k])
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

---Close a minimized harness: remove its bar and send SIGTERM to the process in its terminal. Snacks
-- keeps a terminal buffer open after a non-zero exit (SIGTERM exits with 143), so the buffer is wiped
-- here once the process has exited; the wipe prunes the harness's record and the next <leader>c or <C-q>
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

---Close the window only; the buffer and PTY keep running.
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

---Drop records whose instance exited. Never-opened records (inst nil) are kept.
function M.prune()
  local dead = {}
  for harness, e in pairs(state.table) do
    if e.inst ~= nil and not is_live(e.inst) then
      table.insert(dead, harness) -- collect; removing during pairs() is undefined
    end
  end
  for _, h in ipairs(dead) do
    state.table[h] = nil
  end
end

---Live instances sorted by name. Read-only: exited records are pruned when their buffer goes away.
---@return { harness: string, bufnr: number }[]
function M.list()
  local out = {}
  for harness, e in pairs(state.table) do
    if is_live(e.inst) then
      table.insert(out, { harness = harness, bufnr = e.inst.buf })
    end
  end
  table.sort(out, function(a, b)
    return a.harness < b.harness
  end)
  return out
end

---Test-only: clear the shared state table (instances and their records) without touching any buffer.
function M._reset()
  state._reset()
  M._tiled, M._tile_focus, M._focus_target = false, nil, nil
end

local setup_done = false

---Register what the floats need editor-wide: the WinEnter/FocusGained terminal-mode autocmds, the
-- VimResized re-layout, and the mouse maps. Runs once, on the first M.open, so requiring this module
-- registers nothing.
function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  local group = vim.api.nvim_create_augroup("HarnessTerminalAutoInsert", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local buf = harness_terminal_buf()
      if buf then
        schedule_enter_terminal_mode(vim.api.nvim_get_current_win(), buf)
        -- The focused float's harness is the active one, so <leader>c* sends and edit jumps follow it.
        -- A pending switch (M._focus_target, see M.expect_focus) wins: closing the <C-q> picker lands
        -- focus back on the old float just before the pick moves it to the new one.
        vim.schedule(function()
          local harness = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].harness_terminal
          local sw = require("harness-decorators.switch")
          local pending = M._focus_target ~= nil and M._focus_target ~= harness
          if
            type(harness) == "string"
            and not pending
            and vim.api.nvim_get_current_buf() == buf
            and harness ~= sw.current()
          then
            pcall(sw.activate, harness)
          end
        end)
      end
    end,
  })

  -- Re-focusing nvim (e.g. clicking the window, switching from another terminal) restores terminal
  -- insert mode: some window managers and remote setups drop terminal insert mode on focus loss.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      local buf = harness_terminal_buf()
      -- A user who pressed <C-n> deliberately wants normal mode; FocusGained must not yank them back
      -- into insert (schedule_enter_terminal_mode clears the flag, so only the deliberate re-focus
      -- paths may reset it).
      if buf and not vim.b[buf].harness_terminal_normal_mode then
        schedule_enter_terminal_mode(vim.api.nvim_get_current_win(), buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
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

  M.mouse.setup()
end

M.mouse = require("harness-decorators.mouse")
M.mouse.bind({
  is_live = is_live,
  restore_from_bar = restore_from_bar,
  close_harness = close_harness,
  shelf_button = function(inst)
    M.shelf_button(inst)
  end,
})

return M
