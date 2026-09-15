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

local function enter_terminal_mode(win, buf)
  if
    not vim.api.nvim_win_is_valid(win)
    or not vim.api.nvim_buf_is_valid(buf)
    or vim.api.nvim_get_current_win() ~= win
    or vim.api.nvim_win_get_buf(win) ~= buf
    or vim.bo[buf].buftype ~= "terminal"
    or not vim.b[buf].harness_terminal
  then
    return
  end
  if vim.fn.mode(1) == "t" then
    return
  end
  vim.cmd.startinsert()
end

vim.api.nvim_create_autocmd("WinEnter", {
  group = auto_insert_group,
  callback = function(args)
    local buf = args.buf
    if not vim.b[buf].harness_terminal then
      return
    end
    local win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      enter_terminal_mode(win, buf)
    end)
  end,
})

---Deferred to the next tick (same reasoning as the old enter_insert_scheduled: snacks.open and a
-- re-focus both return before the window/buffer has settled, so a synchronous startinsert does not
-- reliably stick). Needed IN ADDITION to the WinEnter autocmd above: WinEnter only fires when the
-- target window is not already the current window. Re-selecting a harness whose float already has
-- focus (e.g. pressing <leader>c a second time while sitting in it, or picking the already-active
-- harness from <leader>cl) calls nvim_set_current_win on the window you're already in, which is a
-- no-op and never fires WinEnter - leaving a normal-mode-in-terminal ("-- (terminal) --") float stuck
-- there. Every focus/open path in this module must call this directly rather than depend solely on
-- the autocmd.
---@param win integer?
---@param buf integer?
local function schedule_enter_terminal_mode(win, buf)
  if not win or not buf then
    return
  end
  vim.schedule(function()
    enter_terminal_mode(win, buf)
  end)
end

---The shared per-harness record for `harness`, creating it if absent. Every instance read/write in
-- this module goes through the single accessor in state.lua so term and park never diverge (Task 8).
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

---Collapse the float back to its saved (non-wide) config, animated. Ported from ai-harness.lua; the
-- animation helper is shared (lua/terminal-animations.lua).
local function animate_collapse(self)
  if not (self._wide and self._saved_config) then
    return
  end
  self._wide = false
  local sc = self._saved_config
  local anim = require("terminal-animations")
  anim.animate_resize(self, {
    row = sc.row or 0,
    col = sc.col or 0,
    width = sc.width or vim.o.columns,
    height = sc.height or vim.o.lines,
  }, self._saved_config)
end

---The <C-h> go-back key handler: jump to the window we came from while THIS harness's float stays
-- open and visible. We do NOT hide it - the float is a separate window, so its PTY keeps running
-- regardless of where focus is; hiding would make the panel disappear, which is not what "go back"
-- should do. The collapse animation (if widened via <C-f>) still runs so the float returns to its
-- normal size. Exposed on M (not a local) so tests/go_back_key_spec.lua can drive it with a fake
-- instance and assert the float is NOT hidden.
---@param self table the Snacks terminal instance (has :hide(), :show())
function M.go_back_key(self)
  local focus = require("harness-decorators.focus")
  focus.suppress_next_leave()
  animate_collapse(self)
  if not focus.jump_to_saved() then
    set_prev_win()
  end
  vim.cmd.redraw()
  vim.cmd("noh")
end

---The <Esc> close key handler: exit terminal insert mode and HIDE this harness's float (the panel
-- disappears). Unlike go_back_key, hiding is the point - but we still do NOT kill the process:
-- Snacks' :hide() closes only the window, leaving the buffer/PTY alive so the same session resumes on
-- the next <leader>c / re-pick (that is "parking"). Exposed on M so tests/go_back_key_spec.lua can
-- drive it with a fake instance and assert the float IS hidden.
---@param self table the Snacks terminal instance (has :hide(), :show())
function M.close_key(self)
  -- stopinsert is a no-op unless we're in terminal insert mode; guard it so the handler is safe to
  -- drive from a headless normal-mode context (tests) and never errors if already out of insert.
  pcall(vim.cmd.stopinsert)
  pcall(function()
    self:hide()
  end)
end

---The <C-n> key handler: drop out of terminal insert mode into NORMAL mode. The float stays open and
-- focused; this is just the standard "get out of insert" for a terminal buffer (mirrors <Esc> in a
-- normal buffer, minus the close). Exposed on M so tests can drive it headless with a fake instance.
function M.normal_mode_key()
  vim.cmd.stopinsert()
  vim.cmd("noautocmd stopinsert")
end

---The <C-f> key handler: toggle FULLSCREEN for this float. First press saves the current window
-- config and animates the float out to a near-fullscreen rect (5% vertical / 10% horizontal padding);
-- a second press collapses it back to the saved config via animate_collapse. The save-once guard means
-- repeated toggles don't drift the baseline. Exposed on M so tests can drive it headless with a fake
-- instance and assert the _wide flag flips (the resize itself goes through terminal-animations).
---@param self table the Snacks terminal instance (has .win, ._wide, ._saved_config)
function M.fullscreen_key(self)
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  -- Save original config only once so we don't drift on each toggle.
  if not self._saved_config then
    self._saved_config = vim.api.nvim_win_get_config(win)
  end

  local lines = vim.o.lines
  local cols = vim.o.columns
  local wide_row_pad = 0.05
  local wide_col_pad = 0.1

  if not self._wide then
    self._wide = true
    local anim = require("terminal-animations")
    anim.animate_resize(self, {
      row = wide_row_pad * lines,
      col = wide_col_pad * cols,
      width = (1 - 2 * wide_col_pad) * cols,
      height = (1 - 2 * wide_row_pad) * lines,
    })
  else
    animate_collapse(self)
  end
end

---The shared terminal-mode key legend for EVERY harness float. This is the single home for the
-- keys shown in the float's footer - no per-harness keymap file defines or copies these; all five
-- harnesses get them from here (via win_opts), so a change to one key changes it everywhere. Each
-- entry's handler is a module-level function (close_key / normal_mode_key / go_back_key /
-- fullscreen_key) so tests can drive any of them headless with a fake instance. Exposed on M
-- (as M.terminal_keys) so specs can assert on the legend itself - e.g. that <C-l> is present and
-- bound to the same handler as <C-h>.
---@return table[] keys
function M.terminal_keys()
  return {
    {
      "<Esc>",
      function(self)
        -- Exit insert and CLOSE (hide) the float - the panel goes away but the PTY keeps running,
        -- so it resumes on the next <leader>c. Distinct from <C-h>, which just moves focus back
        -- while leaving the panel visible.
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
      "<C-h>",
      function(self)
        M.go_back_key(self)
      end,
      mode = "t",
      desc = "↩",
    },
    {
      -- Same go-back behavior as <C-h> (move focus back to the work buffer, leave the float visible);
      -- a second binding for people who prefer the right-hand side. Mirrored glyph pairs with <C-h>.
      "<C-l>",
      function(self)
        M.go_back_key(self)
      end,
      mode = "t",
      desc = "↪",
    },
    {
      "<C-f>",
      function(self)
        M.fullscreen_key(self)
      end,
      mode = "t",
      desc = "⛶",
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
    border = "rounded",
    title = title.title(harness),
    b = { harness_terminal = harness },
    -- Snacks' style default maps FloatTitle:SnacksTitle, which overrides the per-segment groups in
    -- `title`. Set winhighlight after all merging is done so our override sticks.
    on_win = function(self)
      pcall(vim.api.nvim_set_option_value, "winhighlight", "FloatFooter:SnacksFooter", { win = self.win })
    end,
    footer_keys = true,
    -- fix_buf disabled (same reason as before): its BufWinEnter swap duplicates buffers during the
    -- float's destroy/recreate. Every key here manages focus explicitly, so nothing relies on it.
    fix_buf = false,
    resize = true,
    stack = true,

    keys = M.terminal_keys(),

    -- TODO: make these...more relative
    row = 0.01,
    col = 0.58,
    width = 0.35,
    height = 0.9,
  }
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
local function focus_instance(inst)
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

  local spawn_cwd = vim.fn.getcwd()
  local inst = snacks.open(cmd, {
    auto_insert = false,
    start_insert = false,
    win = win_opts(harness),
  })
  local e = entry(harness)
  e.inst = inst
  mark_harness_buffer(harness, inst)
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
end

return M
