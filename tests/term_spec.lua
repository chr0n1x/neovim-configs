-- Spec for the per-harness terminal owner (Task 7).
--
-- The whole point of Task 7 is that each harness drives its OWN Snacks floating terminal,
-- tracked in our own table keyed by harness name - NOT claudecode.nvim's single module-level
-- `terminal` handle. This spec stubs Snacks.terminal.open to return a fake instance (a
-- windowless buffer + the hide/buf_valid methods term.lua relies on) and asserts the routing:
--   * open(harness) stores an instance keyed by harness
--   * bufnr(harness) returns it
--   * a second open(same_harness) reuses the existing instance (no second Snacks.open call)
--   * open(other_harness) is independent - two instances coexist (the "no shared global" guarantee)
--   * show/hide route to that harness's own instance, never another's
--
-- Nothing here touches claudecode.nvim: term.lua must be free of it. If a future change sneaks a
-- require("claudecode...") into term.lua the stubbed Snacks.open would still pass these tests, so
-- we also assert term.lua does not load any claudecode module (see the final test).
local helper = require("tests.helper")

describe("term: per-harness Snacks float owner (Task 7)", function()
  local snacks
  local orig_open
  local calls -- { cmd, opts }[] every stubbed open recorded

  ---Build a fake Snacks.terminal instance backed by a windowless buffer.
  local function make_fake(buf)
    return {
      buf = buf,
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
      -- Defined to index self (like real Snacks.win:buf_valid does `self.buf and ...`), so calling it
      -- as a plain function (inst.buf_valid()) would E5108. This is what caught the original bug - term
      -- must call it with method syntax (inst:buf_valid()).
      buf_valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
    }
  end

  setup(function()
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    calls = {}
    -- Each stubbed open returns a fresh fake instance with its own windowless buffer, so two
    -- harnesses genuinely get two distinct buffers (the independence guarantee).
    snacks.open = function(cmd, opts)
      local buf = vim.api.nvim_create_buf(false, true)
      table.insert(calls, { cmd = cmd, opts = opts })
      return make_fake(buf)
    end
  end)

  teardown(function()
    snacks.open = orig_open
  end)

  it("open(harness) stores an instance keyed by harness and bufnr() returns it", function()
    local term = require("harness-decorators.term")
    term._reset()
    local inst = term.open("claude")
    assert.is_not_nil(inst, "open must return the Snacks instance")
    assert.are.equal(inst.buf, term.bufnr("claude"), "bufnr(harness) must be the stored instance's buffer")
  end)

  it("records the spawn cwd so session lookup survives later cwd changes", function()
    local term = require("harness-decorators.term")
    term._reset()
    -- Ensure the current buffer is unnamed so the spawn cwd is getcwd() (not a file's dir).
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(scratch)
    local spawn_cwd = vim.fn.getcwd()
    term.open("crush")
    assert.are.equal(spawn_cwd, term.cwd("crush"))
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end)

  it("a second open(same_harness) reuses the existing instance (no second Snacks.open)", function()
    local term = require("harness-decorators.term")
    term._reset()
    local first = term.open("claude")
    local count_after_first = #calls
    local second = term.open("claude")
    assert.are.equal(count_after_first, #calls, "reopening an existing harness must not call Snacks.open again")
    assert.are.equal(first.buf, second.buf, "reuse must return the SAME instance/buffer")
  end)

  it("open(other_harness) is independent - two instances coexist", function()
    local term = require("harness-decorators.term")
    term._reset()
    local a = term.open("claude")
    local b = term.open("maki")
    assert.is_not_nil(a.buf)
    assert.is_not_nil(b.buf)
    assert.are_not.equal(a.buf, b.buf, "two harnesses must have two distinct buffers (no shared global)")
    assert.are.equal(a.buf, term.bufnr("claude"))
    assert.are.equal(b.buf, term.bufnr("maki"))
  end)

  it("show(harness) routes to that harness's own instance", function()
    local term = require("harness-decorators.term")
    term._reset()
    local a = term.open("claude")
    term.open("maki")
    -- The stubbed fake has win=nil, so focus_instance takes the :show() branch (window "closed").
    local shown = false
    a.show = function()
      shown = true
    end
    term.show("claude")
    assert.is_true(shown, "show(claude) must call claude's own instance :show() when its window is closed")
  end)

  it(
    "show(harness) RE-FOCUSES an already-open window via :focus(), not :show() (regression: <leader>c after <C-h>)",
    function()
      -- The bug: after <C-h> the float's window is still open (only focus moved back to the work buffer).
      -- term.show must then re-focus it. Snacks' :show() on an already-open window takes an early-return
      -- path (:update()) that does NOT move focus, so using it here would do nothing - the exact
      -- "nothing happens" the user hit. With a VALID window, focus_instance must call :focus() instead.
      local term = require("harness-decorators.term")
      term._reset()
      local inst = term.open("claude")

      -- Give the instance a real, valid window so focus_instance takes the :focus() branch.
      local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "right" })
      inst.win = win

      local focused, shown = false, false
      inst.focus = function()
        focused = true
      end
      inst.show = function()
        shown = true
      end

      term.show("claude")
      assert.is_true(focused, "show(claude) with an open window must call :focus() to re-focus the panel")
      assert.is_false(shown, "show(claude) must NOT fall back to :show() when the window is already open")
      pcall(vim.api.nvim_win_close, win, true)
    end
  )

  it("uses one deferred WinEnter handler for every harness terminal", function()
    local term = require("harness-decorators.term")
    term._reset()
    local autocmds = vim.api.nvim_get_autocmds({ group = "HarnessTerminalAutoInsert", event = "WinEnter" })
    assert.are.equal(1, #autocmds, "harness terminals must share one WinEnter autocmd")

    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    local work_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local term_win = vim.api.nvim_get_current_win()
    local term_buf = vim.api.nvim_win_get_buf(term_win)
    vim.b[term_buf].harness_terminal = "claude"
    vim.wait(100, function()
      return false
    end, 25)

    local orig_startinsert = vim.cmd.startinsert
    local insert_calls = 0
    vim.cmd.startinsert = function(...)
      insert_calls = insert_calls + 1
      return orig_startinsert(...)
    end

    vim.api.nvim_set_current_win(work_win)
    vim.api.nvim_set_current_win(term_win)
    assert.are.equal(0, insert_calls, "WinEnter must defer startinsert until navigation has settled")
    -- The window switches above start a windows.nvim resize animation (300ms); terminal-mode entry
    -- waits for it to finish, so allow longer than that.
    vim.wait(800, function()
      return insert_calls > 0
    end, 10)
    assert.is_true(insert_calls > 0, "focusing a harness terminal must enter terminal mode")

    pcall(vim.cmd.stopinsert)
    insert_calls = 0
    vim.api.nvim_exec_autocmds("WinEnter", { buffer = term_buf })
    vim.api.nvim_set_current_win(work_win)
    vim.wait(50, function()
      return false
    end, 10)
    assert.are.equal(0, insert_calls, "deferred startinsert must not run after focus leaves the harness terminal")

    vim.cmd.startinsert = orig_startinsert
    pcall(vim.cmd.stopinsert)
    pcall(vim.api.nvim_win_close, term_win, true)
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
  end)

  it("enters terminal mode directly when the target window is ALREADY current (WinEnter cannot fire)", function()
    -- The bug: nvim_set_current_win on the window you're already in is a no-op and does NOT fire
    -- WinEnter. Re-selecting a harness whose float already has focus (e.g. pressing <leader>c a
    -- second time while sitting in it, in normal-in-terminal mode) went through focus_instance's
    -- :focus() call, which relied solely on the WinEnter autocmd to enter insert - so it silently did
    -- nothing and left the float stuck in "-- (terminal) --". focus_instance/open must trigger insert
    -- directly, not only via WinEnter.
    local term = require("harness-decorators.term")
    term._reset()

    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    vim.wait(100, function()
      return false
    end, 25)
    local term_buf = vim.api.nvim_win_get_buf(win)

    local inst = term.open("claude")
    inst.buf = term_buf
    inst.win = win
    inst.focus = function()
      -- Mirrors real Snacks/nvim behavior: setting the current win to itself is a no-op autocmd-wise.
      vim.api.nvim_set_current_win(win)
    end
    vim.b[term_buf].harness_terminal = "claude"

    pcall(vim.cmd.stopinsert) -- normal-in-terminal, focus already on win - no window transition follows

    local orig_startinsert = vim.cmd.startinsert
    local insert_calls = 0
    vim.cmd.startinsert = function(...)
      insert_calls = insert_calls + 1
      return orig_startinsert(...)
    end

    term.open("claude") -- re-select while already focused
    vim.wait(200, function()
      return insert_calls > 0
    end, 10)
    assert.is_true(insert_calls > 0, "re-selecting an already-focused harness terminal must still enter insert mode")

    vim.cmd.startinsert = orig_startinsert
    pcall(vim.cmd.stopinsert)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
  end)

  it("disables Snacks insert hooks and marks fresh harness terminal buffers", function()
    local term = require("harness-decorators.term")
    term._reset()

    local inst = term.open("claude")
    local opts = calls[#calls].opts
    assert.is_false(opts.auto_insert, "Snacks BufEnter auto-insert must be disabled")
    assert.is_false(opts.start_insert, "Snacks synchronous on_win insert must be disabled")
    assert.are.equal("claude", opts.win.b.harness_terminal)
    assert.are.equal("claude", vim.b[inst.buf].harness_terminal)
  end)

  it("marks an existing harness buffer before refocusing it", function()
    local term = require("harness-decorators.term")
    term._reset()
    local inst = term.open("claude")
    vim.b[inst.buf].harness_terminal = nil

    local win = vim.api.nvim_open_win(inst.buf, false, { split = "right" })
    inst.win = win
    inst.focus = function()
      vim.api.nvim_set_current_win(win)
    end

    term.show("claude")
    assert.are.equal("claude", vim.b[inst.buf].harness_terminal)
    pcall(vim.api.nvim_win_close, win, true)
  end)

  it("open(same_harness) re-focuses an already-open instance via :focus(), not a second Snacks.open", function()
    -- <leader>c routes through term.open; for a live instance whose window is still open it must
    -- re-focus (not respawn, and not no-op like the old :show()-only path did).
    local term = require("harness-decorators.term")
    term._reset()
    local inst = term.open("claude")
    local count_after_first = #calls

    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "right" })
    inst.win = win
    local focused = false
    inst.focus = function()
      focused = true
    end

    term.open("claude")
    assert.are.equal(count_after_first, #calls, "reopening an open harness must not call Snacks.open again")
    assert.is_true(focused, "open(claude) with an open window must re-focus via :focus()")
    pcall(vim.api.nvim_win_close, win, true)
  end)

  it("hide(harness) routes to that harness's own instance", function()
    local term = require("harness-decorators.term")
    term._reset()
    local b = term.open("maki")
    term.open("claude")
    local hidden = false
    b.hide = function()
      hidden = true
    end
    term.hide("maki")
    assert.is_true(hidden, "hide(maki) must call maki's own instance :hide()")
  end)

  it(
    "list() does NOT delete a selected-but-never-opened harness entry (regression: <leader>c dead after opening the picker)",
    function()
      -- The bug: in a fresh instance switch.init seeds state.table["claude"] = {inst=nil, selected=true}.
      -- Opening the <leader>cl picker calls park.list -> term.list, which treated ANY entry without a live
      -- instance as "dead" and DELETED it - wiping claude's selected bit. After that, picking claude (which
      -- early-returns in switch because it is already current) left nothing selected, so <leader>c /
      -- show_selected bailed before term.open and no terminal appeared. list() must only drop entries whose
      -- instance actually EXITED (had a buffer that died), never a harness that was merely selected but not
      -- yet opened (inst=nil).
      local term = require("harness-decorators.term")
      local park = require("harness-decorators.park")
      term._reset()

      -- Seed the fresh-instance state: claude is selected but has never been opened (no instance).
      park.set_selected("claude")
      assert.is_not_nil(require("harness-decorators.state").table["claude"], "precondition: claude record exists")

      -- Opening the picker drives park.list -> term.list. This must NOT delete claude's record.
      local entries = term.list()
      assert.are.equal(0, #entries, "a never-opened harness has no live terminal to list")
      assert.is_not_nil(
        require("harness-decorators.state").table["claude"],
        "list() must not delete a selected-but-never-opened entry"
      )
      assert.are.equal("claude", park.selected_harness(), "selection must survive the picker's list() call")

      -- The downstream effect: show_selected can still open claude (it is still selected).
      local shown = park.show_selected()
      assert.are.equal("claude", shown, "show_selected must still open claude after the picker ran list()")
      term._reset()
    end
  )

  it("list() DOES drop a harness whose instance exited (dead buffer)", function()
    -- The other half of the contract: a harness that WAS opened and whose process has now exited
    -- (buffer wiped) is genuinely dead and must be removed so the picker never offers it. This keeps
    -- the original cleanup behavior intact - we only stopped culling the never-opened case above.
    local term = require("harness-decorators.term")
    term._reset()

    local inst = term.open("claude")
    assert.is_not_nil(
      require("harness-decorators.state").table["claude"],
      "precondition: claude record exists after open"
    )

    -- Simulate the process exiting: wipe the buffer so buf_valid() is false.
    pcall(vim.api.nvim_buf_delete, inst.buf, { force = true })
    local entries = term.list()
    assert.are.equal(0, #entries, "an exited harness must not be listed")
    assert.is_nil(
      require("harness-decorators.state").table["claude"],
      "list() must drop an entry whose instance exited"
    )
    term._reset()
  end)

  it("list() calls buf_valid with method syntax (regression: E5108 on plain-function call)", function()
    -- The fake's buf_valid indexes self (like real Snacks). If term.list called inst.buf_valid() as a
    -- plain function, self would be nil and this would raise E5108 - the exact <leader>cl crash. This
    -- drives list() over a live instance to prove it uses method syntax.
    local term = require("harness-decorators.term")
    term._reset()
    local inst = term.open("claude")
    local ok, err = pcall(term.list)
    assert.is_true(ok, "term.list raised (buf_valid called without self): " .. tostring(err))
    local entries = assert(ok and term.list())
    assert.equal(1, #entries, "list should include the live harness")
    assert.are.equal(inst.buf, entries[1].bufnr)
  end)

  it("spawn cwd is the current buffer's dir when it names a real file (project-scoped resume)", function()
    -- The point of project-scoped resume: when you are editing a file in /proj/a, the harness
    -- spawns in /proj/a so `--continue` resumes /proj/a's session, not getcwd()'s.
    local term = require("harness-decorators.term")
    term._reset()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = dir .. "/main.lua"
    local f = io.open(file, "w")
    f:write("local x = 1\n")
    f:close()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, file)
    vim.api.nvim_set_current_buf(buf)
    term.open("maki")
    assert.are.equal(dir, term.cwd("maki"), "spawn cwd must be the edited file's directory")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    term._reset()
  end)

  it("spawn cwd falls back to getcwd() when the current buffer is a scratch/unnamed file", function()
    -- A [No Name] or scratch buffer has no directory; the harness must spawn in getcwd() as before.
    local term = require("harness-decorators.term")
    term._reset()
    local expect = vim.fn.getcwd()
    local buf = vim.api.nvim_create_buf(false, true) -- unnamed scratch buffer
    vim.api.nvim_set_current_buf(buf)
    term.open("maki")
    assert.are.equal(expect, term.cwd("maki"), "unnamed buffer must fall back to getcwd()")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    term._reset()
  end)

  it("does not require any claudecode module (the whole point of the swap)", function()
    -- Snapshot which claudecode modules are loaded, load term.lua fresh, and confirm none were added.
    local before = {}
    for k in pairs(package.loaded) do
      if k:match("^claudecode") then
        before[k] = true
      end
    end
    package.loaded["harness-decorators.term"] = nil
    local term = require("harness-decorators.term")
    assert.is_not_nil(term, "term.lua must load")
    for k in pairs(package.loaded) do
      if k:match("^claudecode") and not before[k] then
        fail("term.lua must not load claudecode modules; it loaded: " .. k)
      end
    end
  end)
end)

-- Spec for the float's mouse handling, minimized bars and output flash. Headless Neovim gets no real
-- mouse input, so these drive term.mouse.press/drag/release/double (the same functions the mouse
-- mappings call) with made-up getmousepos()-shaped positions.
--
-- The fake Snacks instance here owns a REAL float window over a scratch buffer, so geometry is real.
-- With the default 80x24 headless editor and opts { row = 2, col = 10, width = 40, height = 10 } the
-- float's border spans 1-based screen rows 3..14 and columns 11..52:
--
-- ```lua
-- { top = 3, bottom = 14, left = 11, right = 52 } -- title bar is row 3, minimize corner is (3, 52)
-- ```
--
-- Positions in the specs below are derived from that box.
describe("term: float mouse handling, minimized bars and flash", function()
  local term = require("harness-decorators.term")
  local state = require("harness-decorators.state")
  local sw = require("harness-decorators.switch")
  local keymaps = require("harness-decorators.keymaps")
  local utils = require("harness-decorators.utils")
  local snacks
  local orig_open
  local orig_notify
  local original_harness
  local orig_env

  ---A fake Snacks instance whose show() opens a real bordered float at its opts geometry.
  local function make_float_fake(buf)
    local inst = { buf = buf, opts = { border = "rounded", row = 2, col = 10, width = 40, height = 10 } }
    function inst:buf_valid()
      return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
    end
    function inst:show()
      self.win = vim.api.nvim_open_win(self.buf, true, {
        relative = "editor",
        row = self.opts.row,
        col = self.opts.col,
        width = self.opts.width,
        height = self.opts.height,
        border = "rounded",
        -- Snacks renders the key legend as the footer.
        footer = { { " legend ", "SnacksFooter" } },
      })
    end
    function inst:hide()
      if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
      end
      self.win = nil
    end
    function inst:focus()
      vim.api.nvim_set_current_win(self.win)
    end
    function inst.close() end
    return inst
  end

  -- 3s default: a 300ms bar or float animation can take over a second late in the full suite, where
  -- earlier spec files leave windows, terminals and pollers behind. Every default-timeout wait here
  -- expects its condition to come true, so the budget only matters when a spec is failing.
  local function wait_for(pred, ms)
    return vim.wait(ms or 3000, pred, 10)
  end

  local function bar_of(harness)
    local e = state.table[harness]
    local bar = e and e.inst and e.inst._pill_win
    return (bar and vim.api.nvim_win_is_valid(bar)) and bar or nil
  end

  ---The row a docked bar in `slot` settles on (1 is the top of the dock, under any tabline).
  local function dock_row(slot)
    local stal = vim.o.showtabline
    local top = (stal == 2 or (stal == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
    return top + 3 * (slot - 1)
  end

  ---1-based screen position of a bar's text cell `x` (0-based column within its text).
  local function bar_text_pos(bar, x)
    local pos = vim.api.nvim_win_get_position(bar)
    return { screenrow = pos[1] + 2, screencol = pos[2] + 2 + x }
  end

  local function cleanup()
    for _, e in pairs(state.table) do
      local i = e.inst
      if i then
        if i._bar_anim then
          i._bar_anim:finish()
        end
        if i._pill_win and vim.api.nvim_win_is_valid(i._pill_win) then
          vim.api.nvim_win_close(i._pill_win, true)
        end
        if i.win and vim.api.nvim_win_is_valid(i.win) then
          vim.api.nvim_win_close(i.win, true)
        end
      end
    end
    term._reset()
    term.mouse.release()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  setup(function()
    original_harness = helper.active_harness()
    orig_env = os.getenv("NVIM_LLM_HARNESS")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
      inst:show()
      return inst
    end
    orig_notify = vim.notify
    vim.notify = function() end
  end)

  teardown(function()
    snacks.open = orig_open
    vim.notify = orig_notify
    cleanup()
    -- The restore-button spec switches harness; put the config's default back the way switch_spec does.
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    utils.harness = original_harness
    sw.init(original_harness)
    keymaps.clear()
    keymaps.apply(keymaps.build(original_harness))
  end)

  before_each(cleanup)

  it(
    "Given an open harness float, When its title bar is dragged, Then the float moves and keeps the spot for the next show",
    function()
      local inst = term.open("claude")
      assert.are.equal("", term.mouse.press({ screenrow = 3, screencol = 20 }), "title bar press must start a drag")
      term.mouse.drag({ screenrow = 6, screencol = 25 })
      assert.is_true(
        wait_for(function()
          return vim.api.nvim_win_get_config(inst.win).row == 5
        end),
        "float should follow the drag down 3 rows"
      )
      term.mouse.release()
      local cfg = vim.api.nvim_win_get_config(inst.win)
      assert.are.same({ 5, 15 }, { cfg.row, cfg.col })
      assert.are.same({ 5, 15 }, { inst.opts.row, inst.opts.col }, "new position must be kept in opts for show()")
    end
  )

  it(
    "Given an open harness float, When its bottom-right corner is dragged, Then it grows and the <C-f> baseline is dropped",
    function()
      local inst = term.open("claude")
      inst._saved_config = { row_ratio = 0, col_ratio = 0, width_ratio = 1, height_ratio = 1 }
      term.mouse.press({ screenrow = 14, screencol = 52 })
      term.mouse.drag({ screenrow = 16, screencol = 60 })
      assert.is_true(
        wait_for(function()
          return vim.api.nvim_win_get_config(inst.win).width == 48
        end),
        "float should widen by the 8-column drag"
      )
      term.mouse.release()
      local cfg = vim.api.nvim_win_get_config(inst.win)
      assert.are.same({ 48, 12 }, { cfg.width, cfg.height })
      assert.is_nil(inst._saved_config, "the <C-f> collapse target must be the resized geometry")
    end
  )

  it(
    "Given a float Neovim draws away from its config position, When its drawn title bar is pressed, Then the press starts a drag",
    function()
      local inst = term.open("claude")
      -- Neovim shifts a float that does not fit; stand in for that by reporting a drawn spot 5 columns left.
      local orig_pos = vim.api.nvim_win_get_position
      vim.api.nvim_win_get_position = function(w)
        if w == inst.win then
          return { 2, 5 }
        end
        return orig_pos(w)
      end
      local keys = term.mouse.press({ screenrow = 3, screencol = 7 })
      vim.api.nvim_win_get_position = orig_pos
      term.mouse.release()
      assert.are.equal("", keys, "column 7 is on the drawn title bar (config says it starts at 11)")
    end
  )

  it(
    "Given an open harness float, When its minimize corner is double-clicked, Then the window hides, the buffer stays and a bar docks top-right",
    function()
      local inst = term.open("claude")
      assert.are.equal("", term.mouse.double({ screenrow = 3, screencol = 52 }))
      assert.is_true(
        wait_for(function()
          local bar = bar_of("claude")
          local cfg = bar and vim.api.nvim_win_get_config(bar)
          return cfg ~= nil
            and cfg.row == dock_row(1)
            and cfg.height == 1
            and cfg.width == inst._bar_width
            and cfg.col == vim.o.columns - cfg.width - 2
        end),
        "a bar should finish shrinking into the first dock slot, its right border on the last column"
      )
      assert.is_nil(inst.win, "the float window must be hidden")
      assert.is_true(vim.api.nvim_buf_is_valid(inst.buf), "the harness buffer (its process) must survive")
      local bar = bar_of("claude")
      local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bar), 0, 1, false)[1]
      assert.is_truthy(text:find("Claude", 1, true), "the bar must show the harness name: " .. text)
    end
  )

  it(
    "Given a docked bar, When its harness is restored, Then the bar grows back to the float's spot before the float opens",
    function()
      local inst = term.open("claude")
      term.minimize("claude")
      assert.is_true(wait_for(function()
        local bar = bar_of("claude")
        return bar ~= nil and vim.api.nvim_win_get_config(bar).height == 1
      end))
      local bar = bar_of("claude")
      local docked_width = vim.api.nvim_win_get_config(bar).width
      term.show("claude")
      assert.is_nil(inst.win, "the float must wait for the bar to finish growing")
      local grew = wait_for(function()
        return vim.api.nvim_win_is_valid(bar) and vim.api.nvim_win_get_config(bar).width > docked_width
      end, 400)
      assert.is_true(grew, "the bar should grow toward the float's size")
      assert.is_true(
        wait_for(function()
          return inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win) and bar_of("claude") == nil
        end),
        "the float should open and the bar close once the animation ends"
      )
      local cfg = vim.api.nvim_win_get_config(inst.win)
      assert.are.same({ 2, 10, 40, 10 }, { cfg.row, cfg.col, cfg.width, cfg.height }, "the float returns to its spot")
    end
  )

  it(
    "Given an open harness float, When <Esc> is pressed in it, Then it minimizes into a docked bar instead of vanishing",
    function()
      local inst = term.open("claude")
      term.close_key(inst)
      assert.is_true(
        wait_for(function()
          return bar_of("claude") ~= nil
        end),
        "<Esc> should leave a minimized bar in the dock"
      )
      assert.is_nil(inst.win, "the float window must be hidden")
      assert.is_true(vim.api.nvim_buf_is_valid(inst.buf), "the harness buffer (its process) must survive")
    end
  )

  it(
    "Given two docked bars, When the slot-1 bar's close button is clicked, Then it closes and the other slides into slot 1",
    function()
      term.open("claude")
      term.open("maki")
      term.minimize("claude")
      term.minimize("maki")
      assert.is_true(
        wait_for(function()
          local a, b = bar_of("claude"), bar_of("maki")
          return a
            and b
            and vim.api.nvim_win_get_config(a).row == dock_row(1)
            and vim.api.nvim_win_get_config(b).row == dock_row(2)
        end),
        "claude should dock in slot 1 and maki below it in slot 2"
      )
      local inst = state.table.claude.inst
      term.mouse.press(bar_text_pos(bar_of("claude"), inst._bar_close_col))
      assert.is_true(
        wait_for(function()
          local b = bar_of("maki")
          return bar_of("claude") == nil and b ~= nil and vim.api.nvim_win_get_config(b).row == dock_row(1)
        end),
        "claude's bar should close and maki's should slide up to slot 1"
      )
    end
  )

  it(
    "Given a bar still shrinking from its float, When the dock repacks, Then the bar ends at its final width",
    function()
      term.open("claude")
      term.open("maki")
      term.minimize("claude")
      assert.is_true(wait_for(function()
        local a = bar_of("claude")
        return a ~= nil and vim.api.nvim_win_get_config(a).row == dock_row(1)
      end))
      -- maki starts shrinking; closing claude's bar repacks the dock in the middle of that animation.
      term.minimize("maki")
      local claude = state.table.claude.inst
      term.mouse.press(bar_text_pos(bar_of("claude"), claude._bar_close_col))
      local maki = state.table.maki.inst
      assert.is_true(wait_for(function()
        local b = bar_of("maki")
        return b ~= nil and vim.api.nvim_win_get_config(b).row == dock_row(1)
      end))
      vim.wait(500)
      assert.are.equal(
        maki._bar_width,
        vim.api.nvim_win_get_config(bar_of("maki")).width,
        "the repack must target the bar's final width, not its width mid-animation"
      )
    end
  )

  it(
    "Given a docked bar, When its restore button is clicked, Then that harness becomes current and its float opens",
    function()
      term.open("copilot")
      term.minimize("copilot")
      assert.is_true(wait_for(function()
        return bar_of("copilot") ~= nil
      end))
      local inst = state.table.copilot.inst
      -- The restore icon sits 3 columns left of the close icon.
      term.mouse.press(bar_text_pos(bar_of("copilot"), inst._bar_close_col - 3))
      assert.is_true(
        wait_for(function()
          return bar_of("copilot") == nil and inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win)
        end),
        "copilot's float should reopen and its bar close"
      )
      assert.are.equal("copilot", sw.current(), "restoring from the bar must switch to that harness")
    end
  )

  it(
    "Given a docked bar, When its restore button is pressed and released, Then the release is swallowed so focus stays in the restored float",
    function()
      term.open("copilot")
      term.minimize("copilot")
      assert.is_true(wait_for(function()
        return bar_of("copilot") ~= nil
      end))
      local inst = state.table.copilot.inst
      local pos = bar_text_pos(bar_of("copilot"), inst._bar_close_col - 3)
      assert.are.equal("", term.mouse.press(pos))
      -- A drag or release passed through to Neovim would move the cursor to the window under the mouse.
      assert.are.equal("", term.mouse.drag(pos), "a drag after a button press must not reach Neovim")
      assert.are.equal("", term.mouse.release(), "the release after a button press must not reach Neovim")
      assert.is_true(wait_for(function()
        return inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win)
      end))
      assert.are.equal(inst.win, vim.api.nvim_get_current_win(), "the restored float must have focus")
      assert.are.equal("<LeftRelease>", term.mouse.release(), "a later, unrelated release passes through")
    end
  )

  it(
    "Given a docked bar of a running harness, When its close button is clicked, Then the harness process gets SIGTERM, the bar closes and the harness is gone",
    function()
      local exit_code
      -- This harness's buffer runs a real process, so the signal can be observed through its exit code.
      snacks.open = function()
        local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
        vim.api.nvim_buf_call(inst.buf, function()
          vim.fn.jobstart({ "sleep", "60" }, {
            term = true,
            on_exit = function(_, code)
              exit_code = code
            end,
          })
        end)
        inst:show()
        return inst
      end
      term.open("claude")
      snacks.open = function()
        local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
        inst:show()
        return inst
      end
      term.minimize("claude")
      assert.is_true(wait_for(function()
        return bar_of("claude") ~= nil
      end))
      local inst = state.table.claude.inst
      term.mouse.press(bar_text_pos(bar_of("claude"), inst._bar_close_col))
      term.mouse.release()
      assert.is_true(
        wait_for(function()
          return exit_code ~= nil
        end, 2000),
        "the harness process should exit"
      )
      assert.are.equal(128 + 15, exit_code, "the harness process must be ended by SIGTERM")
      assert.is_nil(bar_of("claude"), "the bar must close")
      -- Snacks keeps a terminal buffer open after a non-zero exit; the harness must not linger as "open",
      -- or the next <leader>c would re-show the dead terminal instead of starting a fresh session.
      assert.is_true(
        wait_for(function()
          return not term.is_open("claude")
        end),
        "the ended harness must no longer count as open"
      )
    end
  )

  it(
    "Given the default placement, When a harness float opens, Then its right border stays left of the minimized-bar dock",
    function()
      local win_opts
      snacks.open = function(_, opts)
        win_opts = opts.win
        local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
        inst:show()
        return inst
      end
      term.open("claude")
      snacks.open = function()
        local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
        inst:show()
        return inst
      end
      -- Snacks resolves a ratio as floor(columns * ratio) and calls a function value for the absolute column.
      local cols = vim.o.columns
      local col = type(win_opts.col) == "function" and win_opts.col() or math.floor(cols * win_opts.col)
      local width = type(win_opts.width) == "function" and win_opts.width() or win_opts.width
      local outer_width = math.floor(cols * width)
      -- A docked bar is at least 18 text columns plus its 2 border columns, flush with the last column.
      local dock_left = cols - 20
      assert.is_true(
        col + outer_width <= dock_left - 1,
        string.format("float spans columns %d..%d, the dock starts at %d", col, col + outer_width - 1, dock_left)
      )
    end
  )

  it(
    "Given a float dragged under the dock, When harnesses are minimized, Then the bars draw above the float",
    function()
      local open = term.open("claude")
      term.open("maki")
      term.minimize("maki")
      assert.is_true(wait_for(function()
        return bar_of("maki") ~= nil
      end))
      local claude = state.table.claude.inst
      claude:show()
      local float_z = vim.api.nvim_win_get_config(claude.win).zindex or 50
      assert.is_true(
        vim.api.nvim_win_get_config(bar_of("maki")).zindex > float_z,
        "bars must stack above harness floats"
      )
      assert.is_not_nil(open)
    end
  )

  it(
    "Given the active harness's process exits, When it is started again, Then session following stops on exit and restarts on the new start",
    function()
      local watcher = require("harness-decorators.watcher")
      local orig_stop, orig_start, orig_harness = watcher.stop, watcher.start, utils.harness
      local stops, starts = 0, 0
      watcher.stop = function()
        stops = stops + 1
      end
      watcher.start = function()
        starts = starts + 1
      end
      utils.harness = "claude"
      local exited = false
      snacks.open = function()
        local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
        vim.api.nvim_buf_call(inst.buf, function()
          vim.fn.jobstart({ "sleep", "60" }, {
            term = true,
            on_exit = function()
              exited = true
            end,
          })
        end)
        inst:show()
        return inst
      end
      local inst = term.open("claude")
      vim.fn.jobstop(vim.bo[inst.buf].channel)
      local stopped = wait_for(function()
        return exited and stops > 0
      end, 2000)
      local starts_before_reopen = starts
      term._reset()
      term.open("claude")
      local restarted = starts > starts_before_reopen
      watcher.stop, watcher.start, utils.harness = orig_stop, orig_start, orig_harness
      snacks.open = function()
        local fake = make_float_fake(vim.api.nvim_create_buf(false, true))
        fake:show()
        return fake
      end
      assert.is_true(stopped, "the watcher must stop when the active harness's process exits")
      assert.is_true(restarted, "starting the harness again must restart the watcher")
    end
  )

  it(
    "Given an unfocused harness float, When its terminal gets new text and then goes quiet, Then the border flashes",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      local orig_quiet = term.flash_quiet_ms
      term.flash_quiet_ms = 50
      vim.api.nvim_set_current_win(work_win)
      vim.api.nvim_buf_set_lines(inst.buf, 0, -1, false, { "new output" })
      local flashed = wait_for(function()
        return vim.wo[inst.win].winhighlight:find("HarnessFlash", 1, true) ~= nil
      end)
      term.flash_quiet_ms = orig_quiet
      assert.is_true(flashed, "the float's border should flash after the output settles")
    end
  )

  it(
    "Given windows.nvim is animating a split resize, When terminal mode is re-entered, Then startinsert waits for the animation to end",
    function()
      vim.cmd("vsplit")
      assert.is_true(pcall(vim.cmd, "terminal cat"), "could not open a terminal window (cat)")
      local term_buf = vim.api.nvim_get_current_buf()
      vim.b[term_buf].harness_terminal = "claude"
      vim.wait(100, function()
        return false
      end, 25)
      pcall(vim.cmd.stopinsert)

      local module = "windows.lib.resize-windows-animated"
      local real = package.loaded[module]
      local running = true
      package.loaded[module] =
        { _instance = {
          is_running = function()
            return running
          end,
        } }
      local orig_startinsert = vim.cmd.startinsert
      local calls = 0
      vim.cmd.startinsert = function(...)
        calls = calls + 1
        return orig_startinsert(...)
      end

      term.ensure_terminal_mode()
      vim.wait(200)
      local calls_while_animating = calls
      running = false
      local entered = wait_for(function()
        return calls > 0
      end)

      vim.cmd.startinsert = orig_startinsert
      package.loaded[module] = real
      pcall(vim.cmd.stopinsert)
      assert.are.equal(0, calls_while_animating, "startinsert must not run while the resize animation runs")
      assert.is_true(entered, "startinsert must run once the animation has ended")
    end
  )

  it("Given a running harness float, When another harness is picked, Then the running one stays open", function()
    sw.init("claude")
    local inst = term.open("claude")
    sw.switch("copilot")
    sw.after_pick()
    local picked = state.table.copilot and state.table.copilot.inst
    assert.is_true(wait_for(function()
      return picked ~= nil or (state.table.copilot and state.table.copilot.inst) ~= nil
    end))
    picked = state.table.copilot.inst
    assert.is_true(
      picked.win ~= nil and vim.api.nvim_win_is_valid(picked.win),
      "the picked harness's float should be open"
    )
    vim.wait(300)
    assert.is_nil(bar_of("claude"), "claude must not be minimized")
    assert.is_true(inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win), "claude's float must stay open")
  end)
  ---Drive a full press/drag/release through the mouse handlers, letting the scheduled drag apply.
  local function drag_mouse(from, to)
    local keys = term.mouse.press(from)
    term.mouse.drag(to)
    vim.wait(50)
    term.mouse.release()
    return keys
  end

  ---True once the given window's border shows the flash highlight, within ms.
  local function flashes(win, ms)
    return wait_for(function()
      return vim.api.nvim_win_is_valid(win) and vim.wo[win].winhighlight:find("HarnessFlash", 1, true) ~= nil
    end, ms)
  end

  ---Wait until a harness's bar has finished animating into its dock slot.
  local function docked(harness, slot)
    return wait_for(function()
      local bar = bar_of(harness)
      local inst = state.table[harness] and state.table[harness].inst
      if not (bar and inst) then
        return false
      end
      local cfg = vim.api.nvim_win_get_config(bar)
      return cfg.row == dock_row(slot)
        and cfg.height == 1
        and cfg.width == inst._bar_width
        and cfg.col == vim.o.columns - cfg.width - 2
    end)
  end

  it(
    "Given windows.nvim reports a resize animation that never ends, When terminal mode is re-entered, Then startinsert still runs after the 1s cap",
    function()
      vim.cmd("vsplit")
      assert.is_true(pcall(vim.cmd, "terminal cat"), "could not open a terminal window (cat)")
      local term_buf = vim.api.nvim_get_current_buf()
      vim.b[term_buf].harness_terminal = "claude"
      vim.wait(100, function()
        return false
      end, 25)
      pcall(vim.cmd.stopinsert)

      local module = "windows.lib.resize-windows-animated"
      local real = package.loaded[module]
      -- A window closed mid-animation leaves windows.nvim's animation reporting running forever.
      package.loaded[module] =
        { _instance = {
          is_running = function()
            return true
          end,
        } }
      local orig_startinsert = vim.cmd.startinsert
      local calls = 0
      vim.cmd.startinsert = function(...)
        calls = calls + 1
        return orig_startinsert(...)
      end

      term.ensure_terminal_mode()
      vim.wait(600)
      local calls_before_cap = calls
      local entered = wait_for(function()
        return calls > 0
      end, 1500)

      vim.cmd.startinsert = orig_startinsert
      package.loaded[module] = real
      pcall(vim.cmd.stopinsert)
      assert.are.equal(0, calls_before_cap, "startinsert should still wait inside the cap")
      assert.is_true(entered, "startinsert must run once the 1s cap is reached")
    end
  )

  it(
    "Given two docked bars, When the slot-1 bar is dragged away, Then it leaves the dock, the other repacks, and its float reopens on screen",
    function()
      term.open("claude")
      term.open("maki")
      term.minimize("claude")
      term.minimize("maki")
      assert.is_true(docked("claude", 1) and docked("maki", 2), "both bars should settle in the dock")
      local claude = state.table.claude.inst
      -- Grab claude's bar by its name and drag it far down and to the right.
      drag_mouse(bar_text_pos(bar_of("claude"), 3), { screenrow = 40, screencol = 200 })
      assert.is_nil(claude._bar_slot, "a dragged bar leaves the dock")
      assert.is_true(docked("maki", 1), "the remaining bar should slide into slot 1")
      -- The float reopens where the bar was, clamped so the whole 40x10 float fits the 80x24 editor.
      term.show("claude")
      assert.is_true(wait_for(function()
        return claude.win ~= nil and vim.api.nvim_win_is_valid(claude.win)
      end))
      local cfg = vim.api.nvim_win_get_config(claude.win)
      assert.is_true(cfg.col + cfg.width + 2 <= vim.o.columns, "the reopened float must fit horizontally")
      assert.is_true(
        cfg.row + cfg.height + 2 <= vim.o.lines - vim.o.cmdheight,
        "the reopened float must fit vertically"
      )
    end
  )

  it(
    "Given an open harness float, When its left edge is dragged left, Then it widens leftward and its right edge stays put",
    function()
      local inst = term.open("claude")
      drag_mouse({ screenrow = 8, screencol = 11 }, { screenrow = 8, screencol = 6 })
      assert.is_true(wait_for(function()
        return vim.api.nvim_win_get_config(inst.win).width == 45
      end))
      assert.are.equal(5, vim.api.nvim_win_get_config(inst.win).col)
    end
  )

  it("Given an open harness float, When its bottom edge is dragged down, Then only its height grows", function()
    local inst = term.open("claude")
    drag_mouse({ screenrow = 14, screencol = 30 }, { screenrow = 17, screencol = 30 })
    assert.is_true(wait_for(function()
      return vim.api.nvim_win_get_config(inst.win).height == 13
    end))
    local cfg = vim.api.nvim_win_get_config(inst.win)
    assert.are.same({ 2, 10, 40 }, { cfg.row, cfg.col, cfg.width })
  end)

  it(
    "Given an open harness float, When its left edge is dragged past the right edge, Then it stops at the 20-column minimum",
    function()
      local inst = term.open("claude")
      drag_mouse({ screenrow = 8, screencol = 11 }, { screenrow = 8, screencol = 70 })
      assert.is_true(wait_for(function()
        return vim.api.nvim_win_get_config(inst.win).width == 20
      end))
      assert.are.equal(30, vim.api.nvim_win_get_config(inst.win).col, "the right edge (col 50) must not move")
    end
  )

  it(
    "Given an open harness float, When its title bar is dragged past the editor's corner, Then it stops fully on screen",
    function()
      local inst = term.open("claude")
      drag_mouse({ screenrow = 3, screencol = 20 }, { screenrow = 60, screencol = 300 })
      local max_row = vim.o.lines - vim.o.cmdheight - 10 - 2
      assert.is_true(wait_for(function()
        return vim.api.nvim_win_get_config(inst.win).row == max_row
      end))
      assert.are.equal(vim.o.columns - 40 - 2, vim.api.nvim_win_get_config(inst.win).col)
    end
  )

  it("Given a focused harness float, When its terminal gets new text, Then it does not flash", function()
    local inst = term.open("claude")
    local orig_quiet = term.flash_quiet_ms
    term.flash_quiet_ms = 50
    vim.api.nvim_buf_set_lines(inst.buf, 0, -1, false, { "new output" })
    local flashed = flashes(inst.win, 400)
    term.flash_quiet_ms = orig_quiet
    assert.is_false(flashed, "a float you are looking at must not flash")
  end)

  it(
    "Given an unfocused float just resized with the mouse, When the terminal redraws for the new size, Then it does not flash",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      local orig_quiet = term.flash_quiet_ms
      term.flash_quiet_ms = 50
      drag_mouse({ screenrow = 14, screencol = 52 }, { screenrow = 15, screencol = 55 })
      -- The terminal's reflow for the new size shows up as new lines right after the resize.
      vim.api.nvim_buf_set_lines(inst.buf, 0, -1, false, { "reflowed" })
      local flashed = flashes(inst.win, 400)
      term.flash_quiet_ms = orig_quiet
      assert.is_false(flashed, "the redraw after a mouse resize is not new output")
    end
  )

  it("Given a minimized harness, When its terminal gets new text, Then its bar flashes", function()
    local inst = term.open("claude")
    term.minimize("claude")
    assert.is_true(docked("claude", 1))
    local orig_quiet = term.flash_quiet_ms
    term.flash_quiet_ms = 50
    vim.api.nvim_buf_set_lines(inst.buf, 0, -1, false, { "new output" })
    local ns = vim.api.nvim_get_namespaces().harness_flash
    local lit = wait_for(function()
      local bar = bar_of("claude")
      return bar ~= nil and #vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(bar), ns, 0, -1, {}) > 0
    end)
    term.flash_quiet_ms = orig_quiet
    assert.is_true(lit, "the bar's text should light up")
  end)

  it(
    "Given another harness's float is open, When a bar's restore button is clicked, Then the restored float opens and the other stays open",
    function()
      local claude = term.open("claude")
      term.open("copilot")
      term.minimize("copilot")
      assert.is_true(docked("copilot", 1))
      claude:show()
      local copilot = state.table.copilot.inst
      term.mouse.press(bar_text_pos(bar_of("copilot"), copilot._bar_close_col - 3))
      term.mouse.release()
      assert.is_true(
        wait_for(function()
          return copilot.win ~= nil and vim.api.nvim_win_is_valid(copilot.win)
        end),
        "copilot should open"
      )
      vim.wait(300)
      assert.is_nil(bar_of("claude"), "claude must not be minimized")
      assert.is_true(claude.win ~= nil and vim.api.nvim_win_is_valid(claude.win), "claude's float must stay open")
    end
  )

  it(
    "Given a press outside every float and bar, When it is dragged and released, Then all three events pass through to Neovim",
    function()
      term.open("claude")
      assert.are.equal("<LeftMouse>", term.mouse.press({ screenrow = 20, screencol = 5 }))
      assert.are.equal("<LeftDrag>", term.mouse.drag({ screenrow = 21, screencol = 6 }))
      assert.are.equal("<LeftRelease>", term.mouse.release())
    end
  )

  it(
    "Given a docked bar, When it is pressed on its name and dragged, Then the bar moves instead of firing a button",
    function()
      term.open("claude")
      term.minimize("claude")
      assert.is_true(docked("claude", 1))
      local inst = state.table.claude.inst
      local bar = bar_of("claude")
      local start = vim.api.nvim_win_get_position(bar)
      drag_mouse(bar_text_pos(bar, 3), { screenrow = 10, screencol = 40 })
      assert.is_true(
        wait_for(function()
          return vim.api.nvim_win_get_position(bar)[1] ~= start[1]
        end),
        "the bar should follow the drag"
      )
      assert.is_true(vim.api.nvim_win_is_valid(bar), "pressing the name must not close the bar")
      assert.is_nil(inst.win, "pressing the name must not restore the float")
    end
  )

  it(
    "Given a float moved with the mouse, When <C-f> is pressed twice, Then it collapses back to the moved geometry",
    function()
      local inst = term.open("claude")
      drag_mouse({ screenrow = 3, screencol = 20 }, { screenrow = 6, screencol = 25 })
      assert.is_true(wait_for(function()
        return vim.api.nvim_win_get_config(inst.win).row == 5
      end))
      term.fullscreen_key(inst)
      vim.wait(500)
      term.fullscreen_key(inst)
      assert.is_true(
        wait_for(function()
          local cfg = vim.api.nvim_win_get_config(inst.win)
          return math.abs(cfg.row - 5) <= 1 and math.abs(cfg.col - 15) <= 1 and math.abs(cfg.width - 40) <= 1
        end, 1500),
        "the collapse should land where the float was dragged, not where it started"
      )
    end
  )

  it("Given a docked bar, When the editor is resized, Then the bar re-docks against the new right edge", function()
    term.open("claude")
    term.minimize("claude")
    assert.is_true(docked("claude", 1))
    local cols = vim.o.columns
    vim.o.columns = cols - 10
    local redocked = docked("claude", 1)
    vim.o.columns = cols
    vim.wait(400)
    assert.is_true(redocked, "the bar should move to the new last column")
  end)

  it("Given a wide editor, When a harness float opens, Then it is right-anchored to the editor edge", function()
    local cols = vim.o.columns
    vim.o.columns = 343
    local win_opts
    snacks.open = function(_, opts)
      win_opts = opts.win
      local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
      inst:show()
      return inst
    end
    term.open("claude")
    local col = type(win_opts.col) == "function" and win_opts.col() or nil
    snacks.open = function()
      local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
      inst:show()
      return inst
    end
    vim.o.columns = cols
    -- 2 left of right edge = 239, dock avoidance pushes to 220.
    assert.are.equal(220, col, "the float is pushed left to clear the minimized-bar dock")
  end)

  it(
    "Given harnesses with different name lengths, When they are minimized, Then the bars share one width with the icons right-aligned",
    function()
      term.open("pi")
      term.open("copilot")
      term.minimize("pi")
      term.minimize("copilot")
      assert.is_true(docked("pi", 1) and docked("copilot", 2))
      local widths = {}
      for _, h in ipairs({ "pi", "copilot" }) do
        local bar = bar_of(h)
        local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bar), 0, 1, false)[1]
        widths[h] = vim.fn.strdisplaywidth(text)
        assert.is_truthy(text:find("⛶  ⊘ $"), h .. "'s icons must end the bar: " .. text)
        assert.are.equal(widths[h] - 2, state.table[h].inst._bar_close_col, h .. "'s close icon column")
      end
      assert.are.equal(widths.pi, widths.copilot, "short and long names must give the same bar width")
    end
  )

  it("Given two running harness floats, When a third harness is picked, Then all three floats are open", function()
    sw.init("claude")
    term.open("claude")
    term.open("maki")
    sw.switch("copilot")
    sw.after_pick()
    assert.is_true(
      wait_for(function()
        local p = state.table.copilot and state.table.copilot.inst
        return p ~= nil and p.win ~= nil and vim.api.nvim_win_is_valid(p.win)
      end),
      "the picked harness's float should be open"
    )
    vim.wait(300)
    for _, h in ipairs({ "claude", "maki" }) do
      local i = state.table[h].inst
      assert.is_nil(bar_of(h), h .. " must not be minimized")
      assert.is_true(i.win ~= nil and vim.api.nvim_win_is_valid(i.win), h .. "'s float must stay open")
    end
  end)

  -- Shelf: the top-left border corner is the shelf button. Double-clicking it takes the float
  -- fullscreen and then shrinks it to term.shelf_rows rows at the bottom of the editor. While shelf mode
  -- is on, focusing the float grows it to fullscreen and leaving it slides it back down to the shelf.

  ---The <C-f> fullscreen rect for the current editor size: 5% row padding, 10% column padding.
  ---The zen float's inner width while zen is open, else nil.
  local function zen_inner_width()
    local zen = require("zen-mode.view")
    if not zen.is_open() then
      return nil
    end
    local zcfg = vim.api.nvim_win_get_config(zen.win)
    local zw = zcfg.width
    return math.max(math.floor((math.floor(zcfg.col) - 1) / 2), zw + math.floor(zw / 10)) - 2
  end

  ---Fullscreen: 5% vertical / 10% horizontal padding; while zen is open, the zen float's width,
  -- centered.
  local function fullscreen_rect()
    local lines, cols = vim.o.lines, vim.o.columns
    local rect = {
      row = math.floor(0.05 * lines),
      col = math.floor(0.1 * cols),
      width = math.floor((1 - 2 * 0.1) * cols),
      height = math.floor((1 - 2 * 0.05) * lines),
    }
    local zw = zen_inner_width()
    if zw then
      rect.width, rect.col = zw, math.floor((cols - zw - 2) / 2)
    end
    return rect
  end

  ---The shelf: term.shelf_rows rows at the bottom of the fullscreen rect, the normal float's width
  -- (the zen float's while zen is open), centered.
  local function shelf_rect()
    local full = fullscreen_rect()
    local cols = vim.o.columns
    local w = zen_inner_width() or math.floor(cols * 0.30) - 2
    return {
      row = full.row + full.height - term.shelf_rows,
      col = math.floor((cols - w - 2) / 2),
      width = w,
      height = term.shelf_rows,
    }
  end

  ---The default right-side float as Snacks places it from win_opts (row 0, 2 cols left of right
  -- edge with dock avoidance, 30% x 90%).
  local function default_rect()
    local lines, cols = vim.o.lines, vim.o.columns
    local w = math.floor(cols * 0.30)
    local col = math.max(0, math.min(cols - w - 2, cols - 20 - 1 - w))
    return {
      row = 0,
      col = col,
      width = w - 2,
      height = math.floor(lines * 0.90) - 2,
    }
  end

  local function rect_of(win)
    local cfg = vim.api.nvim_win_get_config(win)
    return { row = math.floor(cfg.row), col = math.floor(cfg.col), width = cfg.width, height = cfg.height }
  end

  local function at_rect(inst, rect, ms)
    return wait_for(function()
      return inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win) and vim.deep_equal(rect_of(inst.win), rect)
    end, ms or 1500)
  end

  ---1-based screen position of a float's drawn top-left border corner (the shelf button).
  local function shelf_corner(win)
    local pos = vim.api.nvim_win_get_position(win)
    return { screenrow = pos[1] + 1, screencol = pos[2] + 1 }
  end

  ---Double-click the float's shelf button and wait for the shelf to settle.
  local function shelve(inst)
    local keys = term.mouse.double(shelf_corner(inst.win))
    term.mouse.release()
    return keys == "" and at_rect(inst, shelf_rect())
  end

  it("Given an open harness float, Then its top-left border corner is the shelf button", function()
    local win_opts
    snacks.open = function(_, opts)
      win_opts = opts.win
      local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
      inst:show()
      return inst
    end
    term.open("claude")
    snacks.open = function()
      local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
      inst:show()
      return inst
    end
    assert.are.same({ "⬓", "Special" }, win_opts.border[1])
    assert.are.same({ "◢", "Special" }, win_opts.border[5], "the bottom-right resize grip stays")
  end)

  it(
    "Given an open harness float, When its shelf corner is double-clicked, Then it goes fullscreen, then shrinks to a shelf_rows-tall shelf at the bottom of the editor, scrolled to the end",
    function()
      local inst = term.open("claude")
      local text = {}
      for i = 1, 30 do
        text[i] = "line " .. i
      end
      vim.api.nvim_buf_set_lines(inst.buf, 0, -1, false, text)
      vim.api.nvim_win_set_cursor(inst.win, { 1, 0 })
      assert.are.equal("", term.mouse.double({ screenrow = 3, screencol = 11 }), "(3, 11) is the shelf corner")
      term.mouse.release()
      local tallest = 0
      local shelf = shelf_rect()
      local settled = wait_for(function()
        local r = rect_of(inst.win)
        tallest = math.max(tallest, r.height)
        return vim.deep_equal(r, shelf)
      end, 1500)
      assert.is_true(settled, "the float should settle on the shelf rect: " .. vim.inspect(rect_of(inst.win)))
      assert.is_true(
        tallest > fullscreen_rect().height - 3,
        "it should pass through fullscreen first, tallest was " .. tallest
      )
      assert.is_true(inst._shelved == true, "the float must be marked shelved")
      assert.are.same(
        shelf,
        { row = inst.opts.row, col = inst.opts.col, width = inst.opts.width, height = inst.opts.height },
        "the shelf geometry must be kept in opts for show()"
      )
      -- Only the height changes on the way to a top-anchored shelf, so a late animation frame can
      -- match the shelf rect before the final frame scrolls to the end.
      local last_visible
      wait_for(function()
        vim.cmd.redraw()
        last_visible = vim.api.nvim_win_call(inst.win, function()
          return vim.fn.line("w$")
        end)
        return last_visible == 30
      end, 1000)
      assert.are.equal(30, last_visible, "the shelf must show the end of the terminal (the prompt)")
    end
  )

  it(
    "Given a shelved float, When its shelf corner is double-clicked again, Then it returns to fullscreen and is no longer shelved",
    function()
      local inst = term.open("claude")
      assert.is_true(shelve(inst), "precondition: shelved")
      assert.are.equal("", term.mouse.double(shelf_corner(inst.win)))
      term.mouse.release()
      assert.is_true(at_rect(inst, fullscreen_rect()), "the float should grow back to fullscreen")
      assert.is_false(inst._shelved, "the float must no longer be shelved")
    end
  )

  it(
    "Given a shelved unfocused float, When its terminal gets new text and then goes quiet, Then the shelf bounces instead of flashing",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      -- Past the grace period that ignores the terminal's reflow after a resize.
      vim.wait(600)
      local orig_quiet = term.flash_quiet_ms
      term.flash_quiet_ms = 50
      local base = rect_of(inst.win)
      vim.api.nvim_buf_set_lines(inst.buf, 0, -1, false, { "new output" })
      local height_kept = true
      local lifted = wait_for(function()
        local r = rect_of(inst.win)
        height_kept = height_kept and r.height == base.height
        return r.row < base.row
      end)
      local landed = wait_for(function()
        local r = rect_of(inst.win)
        height_kept = height_kept and r.height == base.height
        return r.row == base.row
      end)
      local flashed = flashes(inst.win, 300)
      term.flash_quiet_ms = orig_quiet
      assert.is_true(lifted, "the shelf should bounce up")
      assert.is_true(landed, "the shelf should come back down to its row")
      assert.is_true(height_kept, "a bounce must not resize the terminal")
      assert.is_false(flashed, "a shelf bounces instead of flashing its border")
    end
  )

  it(
    "Given a shelved float, When it is minimized and restored, Then it comes back in the default spot with shelf mode and fullscreen off",
    function()
      local inst = term.open("claude")
      assert.is_true(shelve(inst), "precondition: shelved")
      term.minimize("claude")
      assert.is_true(docked("claude", 1))
      assert.is_false(inst._shelved == true, "minimizing clears the shelf")
      assert.is_false(inst._shelf_mode == true, "minimizing turns shelf mode off")
      assert.is_false(inst._wide == true, "minimizing clears fullscreen")
      term.show("claude")
      assert.is_true(
        wait_for(function()
          return inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win) and bar_of("claude") == nil
        end),
        "the float should reopen"
      )
      assert.is_true(
        at_rect(inst, default_rect()),
        "the restored float should be in the default spot: " .. vim.inspect(rect_of(inst.win))
      )
    end
  )

  it(
    "Given a float made fullscreen with <C-f>, When it is minimized and restored, Then it comes back in the default spot with shelf mode off",
    function()
      local inst = term.open("claude")
      term.fullscreen_key(inst)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: fullscreen")
      term.minimize("claude")
      assert.is_false(inst._shelf_mode == true)
      assert.is_false(inst._wide == true)
      assert.is_nil(inst._saved_config)
      term.show("claude")
      assert.is_true(
        at_rect(inst, default_rect()),
        "the restored float should be in the default spot: " .. vim.inspect(rect_of(inst.win))
      )
    end
  )

  it(
    "Given a shelved float (shelf mode on), When <C-f> is pressed, Then shelf mode is off and the float leaves the shelf",
    function()
      local inst = term.open("claude")
      assert.is_true(shelve(inst), "precondition: shelved")
      term.fullscreen_key(inst)
      assert.is_false(inst._shelf_mode == true)
      assert.is_false(inst._shelved == true)
      assert.is_true(
        wait_for(function()
          local r = rect_of(inst.win)
          return not vim.deep_equal(r, fullscreen_rect()) and not vim.deep_equal(r, shelf_rect())
        end, 1500),
        "the float should retract: " .. vim.inspect(rect_of(inst.win))
      )
    end
  )

  it(
    "Given a shelved float that is not focused, When <C-l> or <C-h> is pressed, Then the shelf stays in place",
    function()
      local inst = term.open("claude")
      assert.is_true(shelve(inst), "precondition: shelved")
      term.shelf_key(inst)
      vim.wait(400)
      assert.are.same(shelf_rect(), rect_of(inst.win))
      assert.is_true(inst._shelved == true)
    end
  )

  it(
    "Given shelf mode on and the float unfocused, When the float gains focus, Then it grows to fullscreen and shelf mode stays on",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "focus should grow the shelf to fullscreen")
      assert.is_true(inst._shelf_mode == true, "shelf mode stays on while focused")
      assert.is_false(inst._shelved)
    end
  )

  it(
    "Given shelf mode on and an unfocused float that is neither shelved nor fullscreen, When the float gains focus, Then it goes fullscreen",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_win_set_config(inst.win, { relative = "editor", row = 2, col = 10, width = 40, height = 10 })
      inst._shelved = false
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "focus must always unshelve: " .. vim.inspect(rect_of(inst.win)))
    end
  )

  it(
    "Given shelf mode on and the float focused at fullscreen, When focus leaves the float, Then it slides back up to the shelf",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(at_rect(inst, shelf_rect()), "leaving should shelve again: " .. vim.inspect(rect_of(inst.win)))
      assert.is_true(inst._shelved == true)
    end
  )

  it(
    "Given shelf mode off and the float unfocused, When focus moves into and out of it, Then the float does not move",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      local before = rect_of(inst.win)
      vim.api.nvim_set_current_win(inst.win)
      vim.wait(200)
      vim.api.nvim_set_current_win(work_win)
      vim.wait(400)
      assert.are.same(before, rect_of(inst.win))
    end
  )

  it("Given shelf mode on, When <C-f> is pressed, Then shelf mode is off", function()
    local inst = term.open("claude")
    assert.is_true(shelve(inst), "precondition: shelved")
    term.fullscreen_key(inst)
    assert.is_false(inst._shelf_mode == true)
  end)

  it(
    "Given shelf mode on and the float focused at fullscreen, When <C-f> is pressed, Then shelf mode is off and the float retracts",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")
      term.fullscreen_key(inst)
      assert.is_false(inst._shelf_mode == true, "<C-f> must turn shelf mode off")
      assert.is_true(
        wait_for(function()
          local r = rect_of(inst.win)
          return not vim.deep_equal(r, fullscreen_rect()) and not vim.deep_equal(r, shelf_rect())
        end, 1500),
        "the float should retract like a normal <C-f>: " .. vim.inspect(rect_of(inst.win))
      )
    end
  )

  it(
    "Given shelf mode on and the float focused at fullscreen, When <C-l> is pressed, Then focus moves to the tmux pane on the right, shelf mode stays on and the float stays focused at fullscreen",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")

      local real_system, real_tmux = vim.fn.system, vim.env.TMUX
      local calls = {}
      vim.env.TMUX = "/tmp/fake-tmux,1,0"
      vim.fn.system = function(cmd)
        calls[#calls + 1] = type(cmd) == "table" and table.concat(cmd, " ") or cmd
        return ""
      end
      local ok, err = pcall(term.shelf_key, inst)
      vim.fn.system, vim.env.TMUX = real_system, real_tmux
      assert.is_true(ok, tostring(err))

      assert.are.same({ "tmux select-pane -R" }, calls)
      assert.is_true(inst._shelf_mode == true, "shelf mode must stay on")
      vim.wait(400)
      assert.are.equal(inst.win, vim.api.nvim_get_current_win(), "the float must keep nvim focus")
      assert.are.same(fullscreen_rect(), rect_of(inst.win), "the float must stay fullscreen")
    end
  )

  it(
    "Given shelf mode on and the float focused at fullscreen, When <C-h> is pressed, Then focus moves to the tmux pane on the left, shelf mode stays on and the float stays focused at fullscreen",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")

      local real_system, real_tmux = vim.fn.system, vim.env.TMUX
      local calls = {}
      vim.env.TMUX = "/tmp/fake-tmux,1,0"
      vim.fn.system = function(cmd)
        calls[#calls + 1] = type(cmd) == "table" and table.concat(cmd, " ") or cmd
        return ""
      end
      local ok, err = pcall(term.go_back_key, inst)
      vim.fn.system, vim.env.TMUX = real_system, real_tmux
      assert.is_true(ok, tostring(err))

      assert.are.same({ "tmux select-pane -L" }, calls)
      assert.is_true(inst._shelf_mode == true, "shelf mode must stay on")
      vim.wait(400)
      assert.are.equal(inst.win, vim.api.nvim_get_current_win(), "the float must keep nvim focus")
      assert.are.same(fullscreen_rect(), rect_of(inst.win), "the float must stay fullscreen")
    end
  )

  it(
    "Given shelf mode on and the float focused at fullscreen, When <Esc> is pressed, Then the float slides to the shelf instead of minimizing, shelf mode stays on and focus goes back",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")
      require("harness-decorators.focus").last_win = work_win

      term.close_key(inst)

      assert.is_nil(bar_of("claude"), "must not minimize into a docked bar")
      assert.is_true(inst._shelf_mode == true, "shelf mode must stay on")
      assert.are.equal(work_win, vim.api.nvim_get_current_win(), "focus should go back")
      assert.is_true(
        wait_for(function()
          return at_rect(inst, shelf_rect())
        end, 1500),
        "should slide to the shelf: " .. vim.inspect(rect_of(inst.win))
      )
    end
  )

  it(
    "Given a focused float with shelf mode off, When <C-l> is pressed, Then focus goes back to where <C-h> goes and the float does not move",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(inst.win)
      local before = rect_of(inst.win)
      require("harness-decorators.focus").last_win = work_win
      term.shelf_key(inst)
      assert.are.equal(work_win, vim.api.nvim_get_current_win(), "<C-l> should move focus back like <C-h>")
      vim.wait(400)
      assert.are.same(before, rect_of(inst.win), "the float must not move")
      assert.is_false(inst._shelf_mode == true)
    end
  )

  it("Given a shelved float, When <C-h> is pressed, Then the shelf stays in place", function()
    local inst = term.open("claude")
    assert.is_true(shelve(inst), "precondition: shelved")
    term.go_back_key(inst)
    vim.wait(400)
    assert.are.same(shelf_rect(), rect_of(inst.win))
    assert.is_true(inst._shelved)
  end)

  it("Given shelf mode off, When <C-f> is pressed, Then shelf mode is on and the float is fullscreen", function()
    local inst = term.open("claude")
    term.fullscreen_key(inst)
    assert.is_true(inst._shelf_mode == true, "<C-f> must turn shelf mode on")
    assert.is_true(at_rect(inst, fullscreen_rect()), "shelf mode starts fullscreen: " .. vim.inspect(rect_of(inst.win)))
  end)

  it(
    "Given shelf mode on and the float focused at fullscreen outside tmux, When <C-h> or <C-l> is pressed, Then nothing happens",
    function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")
      local real_tmux = vim.env.TMUX
      vim.env.TMUX = nil
      term.go_back_key(inst)
      term.shelf_key(inst)
      vim.env.TMUX = real_tmux
      vim.wait(400)
      assert.are.equal(inst.win, vim.api.nvim_get_current_win(), "focus must stay in the float")
      assert.are.same(fullscreen_rect(), rect_of(inst.win), "the float must stay fullscreen")
      assert.is_true(inst._shelf_mode == true)
    end
  )

  it(
    "Given an open harness float, When its shelf corner is pressed and dragged, Then the float moves and is not shelved",
    function()
      local inst = term.open("claude")
      assert.are.equal("", drag_mouse({ screenrow = 3, screencol = 11 }, { screenrow = 6, screencol = 16 }))
      assert.is_true(
        wait_for(function()
          local cfg = vim.api.nvim_win_get_config(inst.win)
          return cfg.row == 5 and cfg.col == 15
        end),
        "pressing the shelf corner still starts a move"
      )
      assert.is_nil(inst._shelved)
    end
  )

  describe("term.set_zen_width", function()
    local set_config_calls
    local real_set_config

    setup(function()
      real_set_config = vim.api.nvim_win_set_config
      set_config_calls = {}
      vim.api.nvim_win_set_config = function(win, cfg)
        table.insert(set_config_calls, { win = win, cfg = cfg })
        -- Apply width/col to the window so downstream assertions can read it.
        local cur = vim.api.nvim_win_get_config(win)
        local full = {
          relative = "editor",
          row = cfg.row or cur.row,
          col = cfg.col or cur.col,
          width = cfg.width or cur.width,
          height = cfg.height or cur.height,
        }
        return real_set_config(win, full)
      end
    end)

    teardown(function()
      vim.api.nvim_win_set_config = real_set_config
    end)

    it("Given no zen window to measure, When narrow=true, Then all open floats are 20% of the columns wide", function()
      local inst = term.open("claude")
      local cols = vim.o.columns
      term.set_zen_width(true)
      assert.are.equal(math.floor(cols * 0.20) - 2, inst.opts.width)
      assert.is_true(wait_for(function()
        return vim.api.nvim_win_get_config(inst.win).width == math.floor(cols * 0.20) - 2
      end, 1500))
    end)

    it("restores all open floats to the default width and col when narrow=false", function()
      local inst = term.open("claude")
      term.set_zen_width(true)
      term.set_zen_width(false)
      assert.are.equal(0.30, inst.opts.width)
      local cols = vim.o.columns
      local w = math.floor(cols * 0.30)
      local dock_left = cols - 20
      local expected_col = math.max(0, math.min(cols - w - 2, dock_left - 1 - w))
      assert.are.equal(expected_col, inst.opts.col)
    end)

    it("resizes every open harness float, not just the active one", function()
      local a = term.open("claude")
      term.open("maki")
      term.set_zen_width(true)
      local w = math.floor(vim.o.columns * 0.20) - 2
      assert.are.equal(w, a.opts.width)
      local maki_entry = state.table["maki"]
      assert.are.equal(w, maki_entry.inst.opts.width)
    end)

    it("ignores harnesses with no live window", function()
      local inst = term.open("claude")
      -- Minimize the float so its window is replaced by a bar.
      term.minimize("claude")
      -- set_zen_width must not error on the minimized harness.
      term.set_zen_width(true)
      -- The bar is still there and the float is still minimized.
      assert.is_not_nil(inst._pill_win)
    end)
  end)

  describe("term.set_zen_width against real window geometry", function()
    local zen_view = require("zen-mode.view")
    local zen_buf, zen_win

    before_each(function()
      zen_buf = vim.api.nvim_create_buf(false, true)
      local cols = vim.o.columns
      zen_win = vim.api.nvim_open_win(zen_buf, false, {
        relative = "editor",
        row = 0,
        col = math.floor(cols * 0.2),
        width = math.floor(cols * 0.4),
        height = 5,
      })
      zen_view.win = zen_win
    end)

    after_each(function()
      zen_view.win = nil
      pcall(vim.api.nvim_win_close, zen_win, true)
      pcall(vim.api.nvim_buf_delete, zen_buf, { force = true })
    end)

    ---The float's outer span: first column and one past the last, border included.
    local function outer_span(win)
      local cfg = vim.api.nvim_win_get_config(win)
      local bordered = cfg.border ~= nil and cfg.border ~= "none" and not vim.tbl_isempty(cfg.border)
      local col = math.floor(cfg.col)
      return col, col + cfg.width + (bordered and 2 or 0)
    end

    ---The zen float's expected outer span (first column, one past the last) for a zen window at
    -- `zcol`, `zw` wide.
    local function expected_span(cols, zcol, zw)
      local outer = math.max(math.floor((zcol - 1) / 2), zw + math.floor(zw / 10))
      local left = math.max(0, math.min(zcol + math.floor(zw / 4), cols - 20 - outer))
      return left, left + outer
    end

    it(
      "Given zen is open with room on its right, When zen mode resizes the floats, Then the float starts a quarter into the zen window, is 10% wider than it, and fills the top 70% of the screen",
      function()
        local old_cols = vim.o.columns
        vim.o.columns = 300
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 40, width = 120, height = 5 })
        local inst = term.open("claude")
        term.set_zen_width(true)
        local ok = wait_for(function()
          local left, right = outer_span(inst.win)
          local cfg = vim.api.nvim_win_get_config(inst.win)
          return left == 70
            and right == 202
            and math.floor(cfg.row) == 0
            and cfg.height + 2 == math.floor(vim.o.lines * 0.7)
        end, 1500)
        local got = rect_of(inst.win)
        vim.o.columns = old_cols
        assert.is_true(ok, "want cols 70..202, top 70%: " .. vim.inspect(got))
      end
    )

    it(
      "Given a narrow zen window, When zen mode resizes the floats, Then the focused float is at least as wide as the grid's widest cell",
      function()
        local old_cols = vim.o.columns
        vim.o.columns = 300
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 100, width = 40, height = 5 })
        local inst = term.open("claude")
        term.set_zen_width(true)
        local ok = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == 110 and right == 159
        end, 1500)
        local got = rect_of(inst.win)
        vim.o.columns = old_cols
        assert.is_true(ok, "want cols 110..159 (outer 49 = half of the 99-col empty area): " .. vim.inspect(got))
      end
    )

    it(
      "Given little room right of the zen window, When zen mode resizes the floats, Then the float shifts left so it ends where the dock begins",
      function()
        local old_cols = vim.o.columns
        vim.o.columns = 200
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 40, width = 120, height = 5 })
        local inst = term.open("claude")
        term.set_zen_width(true)
        local ok = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == 48 and right == 180
        end, 1500)
        local got = rect_of(inst.win)
        vim.o.columns = old_cols
        assert.is_true(ok, "want cols 48..180: " .. vim.inspect(got))
      end
    )

    local function geom(win)
      local c = vim.api.nvim_win_get_config(win)
      return { row = math.floor(c.row), col = math.floor(c.col), width = c.width, height = c.height }
    end

    it(
      "Given zen is open and the float sits unmoved in its zen spot, When <C-f> goes fullscreen and back, Then the float returns to the zen spot",
      function()
        local inst = term.open("claude")
        term.set_zen_width(true)
        local zen_spot = geom(inst.win)

        term.fullscreen_key(inst)
        vim.wait(500)
        term.fullscreen_key(inst)

        assert.is_true(
          wait_for(function()
            return vim.deep_equal(geom(inst.win), zen_spot)
          end, 1500),
          ("expected %s, got %s"):format(vim.inspect(zen_spot), vim.inspect(geom(inst.win)))
        )
      end
    )

    it(
      "Given the float sits unmoved in its default spot, When <C-f> goes fullscreen, zen opens, and <C-f> retracts, Then the float lands in the zen spot",
      function()
        zen_view.win = nil
        local inst = term.open("claude")
        local lines, cols = vim.o.lines, vim.o.columns
        local w = math.floor(cols * 0.30)
        -- Where Snacks puts a float opened with the default options: row 0 stays 0 (Snacks only
        -- offsets fractional rows strictly between 0 and 1), sizes are fractions minus the border.
        vim.api.nvim_win_set_config(inst.win, {
          relative = "editor",
          row = 0,
          col = math.max(0, math.min(cols - w - 2, cols - 20 - 1 - w)),
          width = w - 2,
          height = math.floor(lines * 0.90) - 2,
        })
        term.fullscreen_key(inst)
        vim.wait(500)

        zen_view.win = zen_win
        term.fullscreen_key(inst)

        local zcfg = vim.api.nvim_win_get_config(zen_win)
        local want_l, want_r = expected_span(cols, zcfg.col, zcfg.width)
        assert.is_true(
          wait_for(function()
            local left, right = outer_span(inst.win)
            return left == want_l and right == want_r
          end, 1500),
          "expected the zen spot, got " .. vim.inspect(geom(inst.win))
        )
      end
    )

    local function place(inst, rect)
      vim.api.nvim_win_set_config(inst.win, vim.tbl_extend("force", { relative = "editor" }, rect))
    end

    it(
      "Given zen is open and shelf mode off, When the float loses focus, Then it shrinks from the left to just past the zen window, keeping its right edge and height",
      function()
        local old_cols = vim.o.columns
        vim.o.columns = 300
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 40, width = 120, height = 5 })
        local work_win = vim.api.nvim_get_current_win()
        local inst = term.open("claude")
        vim.api.nvim_set_current_win(inst.win)
        term.set_zen_width(true)
        local focused_ok = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == 70 and right == 202
        end, 1500)
        local height = vim.api.nvim_win_get_config(inst.win).height
        vim.api.nvim_set_current_win(work_win)
        local ok = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == 161 and right == 202 and vim.api.nvim_win_get_config(inst.win).height == height
        end, 1500)
        local got = rect_of(inst.win)
        vim.o.columns = old_cols
        assert.is_true(focused_ok, "precondition: focused float in the zen spot")
        assert.is_true(ok, "want cols 161..202 at the same height: " .. vim.inspect(got))
      end
    )

    it(
      "Given zen is open, shelf mode off and the float moved aside, When the float gains focus, Then it grows back to the zen spot",
      function()
        local old_cols = vim.o.columns
        vim.o.columns = 300
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 40, width = 120, height = 5 })
        local work_win = vim.api.nvim_get_current_win()
        local inst = term.open("claude")
        vim.api.nvim_set_current_win(work_win)
        term.set_zen_width(true)
        local aside = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == 161 and right == 202
        end, 1500)
        vim.api.nvim_set_current_win(inst.win)
        local ok = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == 70 and right == 202
        end, 1500)
        local got = rect_of(inst.win)
        vim.o.columns = old_cols
        assert.is_true(aside, "precondition: unfocused float moved aside")
        assert.is_true(ok, "want cols 70..202: " .. vim.inspect(got))
      end
    )

    it(
      "Given a minimized harness, When zen mode opens, Then its bar docks just right of the zen float, at the top",
      function()
        local old_cols = vim.o.columns
        vim.o.columns = 200
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 40, width = 120, height = 5 })
        local inst = term.open("claude")
        term.open("maki")
        term.minimize("maki")
        term.set_zen_width(true)
        local ok = wait_for(function()
          local bar = bar_of("maki")
          if not bar then
            return false
          end
          local _, right = outer_span(inst.win)
          local cfg = vim.api.nvim_win_get_config(bar)
          return math.floor(cfg.col) == right and cfg.row == dock_row(1)
        end, 1500)
        local _, right = outer_span(inst.win)
        local bar = bar_of("maki")
        local got = bar and vim.api.nvim_win_get_config(bar)
        vim.o.columns = old_cols
        assert.is_true(ok, ("float ends at %d, bar at %s"):format(right, vim.inspect(got and { got.row, got.col })))
      end
    )

    it(
      "Given zen is open and the float sits in the zen spot, When the editor is resized, Then the float is re-placed for the new size",
      function()
        local inst = term.open("claude")
        term.set_zen_width(true)
        local old_cols = vim.o.columns
        vim.o.columns = old_cols - 30
        vim.api.nvim_exec_autocmds("VimResized", {})
        local zcfg = vim.api.nvim_win_get_config(zen_win)
        local want_l, want_r = expected_span(vim.o.columns, zcfg.col, zcfg.width)
        local ok = wait_for(function()
          local left, right = outer_span(inst.win)
          return left == want_l and right == want_r
        end, 1000)
        local _, right = outer_span(inst.win)
        local cols = vim.o.columns
        vim.o.columns = old_cols
        assert.is_true(ok, ("float ends at %d, want %d"):format(right, want_r))
      end
    )

    it(
      "Given shelf mode on and an unfocused float at fullscreen, When zen mode opens, Then the float slides onto the shelf",
      function()
        local inst = term.open("claude")
        assert.is_true(shelve(inst), "precondition: shelved")
        place(inst, fullscreen_rect())
        inst._shelved = false
        term.set_zen_width(true)
        assert.is_true(at_rect(inst, shelf_rect()), "should land on the shelf: " .. vim.inspect(rect_of(inst.win)))
        assert.is_true(inst._shelved == true)
      end
    )

    it(
      "Given shelf mode on and a shelved float off its shelf rect, When zen mode opens, Then it slides back onto the shelf",
      function()
        local inst = term.open("claude")
        assert.is_true(shelve(inst), "precondition: shelved")
        local off = shelf_rect()
        off.width, off.col = off.width - 7, off.col + 3
        place(inst, off)
        term.set_zen_width(true)
        assert.is_true(at_rect(inst, shelf_rect()), "should land on the shelf: " .. vim.inspect(rect_of(inst.win)))
      end
    )

    it("Given shelf mode on and the float focused, When zen mode opens, Then the float grows to fullscreen", function()
      local work_win = vim.api.nvim_get_current_win()
      local inst = term.open("claude")
      vim.api.nvim_set_current_win(work_win)
      assert.is_true(shelve(inst), "precondition: shelved")
      vim.api.nvim_set_current_win(inst.win)
      assert.is_true(at_rect(inst, fullscreen_rect()), "precondition: focused at fullscreen")
      place(inst, shelf_rect())
      term.set_zen_width(true)
      assert.is_true(at_rect(inst, fullscreen_rect()), "should land fullscreen: " .. vim.inspect(rect_of(inst.win)))
    end)
  end)

  -- Tiling readjust (<C-t>): the focused float keeps its normal spot and every other open float
  -- stacks top to bottom, by harness name, in its own column: left of the zen window while zen is
  -- open, else at the far right just left of the dock's reserved space (focused float moves left of
  -- the stack). Focus changes re-tile until reset_layout.
  describe("term.tile", function()
    local zen_view = require("zen-mode.view")
    local zen_buf, zen_win, old_cols

    before_each(function()
      old_cols = vim.o.columns
      vim.o.columns = 300
      zen_buf = vim.api.nvim_create_buf(false, true)
      zen_win =
        vim.api.nvim_open_win(zen_buf, false, { relative = "editor", row = 0, col = 40, width = 120, height = 5 })
      zen_view.win = zen_win
    end)

    after_each(function()
      term._tiled = false
      zen_view.win = nil
      pcall(vim.api.nvim_win_close, zen_win, true)
      pcall(vim.api.nvim_buf_delete, zen_buf, { force = true })
      vim.o.columns = old_cols
    end)

    ---The float's outer geometry (border included).
    local function outer(win)
      local c = vim.api.nvim_win_get_config(win)
      return { row = math.floor(c.row), col = math.floor(c.col), width = c.width + 2, height = c.height + 2 }
    end

    local function lands(inst, want)
      local ok = wait_for(function()
        return vim.deep_equal(outer(inst.win), want)
      end, 1500)
      assert.is_true(ok, ("want %s, got %s"):format(vim.inspect(want), vim.inspect(outer(inst.win))))
    end

    ---The text of a float's footer (the key legend), or "" when it has none.
    local function footer_text(win)
      local f = vim.api.nvim_win_get_config(win).footer
      if type(f) ~= "table" then
        return f or ""
      end
      return table.concat(vim.tbl_map(function(c)
        return type(c) == "table" and c[1] or c
      end, f))
    end

    it("Given two harness floats with claude focused, Then only claude's float shows the key legend", function()
      local copilot = term.open("copilot")
      local claude = term.open("claude")
      vim.api.nvim_set_current_win(claude.win)
      assert.is_true(
        wait_for(function()
          return footer_text(claude.win) ~= "" and footer_text(copilot.win) == ""
        end, 1000),
        ("claude %q, copilot %q"):format(footer_text(claude.win), footer_text(copilot.win))
      )
      vim.api.nvim_set_current_win(copilot.win)
      assert.is_true(
        wait_for(function()
          return footer_text(copilot.win) ~= "" and footer_text(claude.win) == ""
        end, 1000),
        "the legend should follow focus to copilot"
      )
    end)

    it("Given a harness float, Then its legend shows <C-t> as a dot grid and leaves out <C-h> and <C-l>", function()
      local win_opts
      snacks.open = function(_, opts)
        win_opts = opts.win
        local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
        inst:show()
        return inst
      end
      term.open("claude")
      local shown = vim.tbl_map(function(k)
        return k:lower()
      end, win_opts.footer_keys)
      assert.is_true(vim.tbl_contains(shown, "<c-t>"), vim.inspect(shown))
      assert.is_false(vim.tbl_contains(shown, "<c-h>"), vim.inspect(shown))
      assert.is_false(vim.tbl_contains(shown, "<c-l>"), vim.inspect(shown))
      local desc
      for _, k in ipairs(term.terminal_keys()) do
        if k[1] == "<C-t>" then
          desc = k.desc
        end
      end
      assert.are.equal("⣿", desc)
    end)

    it(
      "Given the floats are all in their grid spots, When <C-t> is pressed, Then focus cycles to the next float by name and wraps",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        local stacked = { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) }
        local zen_spot = { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) }
        term.tile()
        lands(copilot, stacked)
        lands(claude, zen_spot)
        term.tile()
        assert.are.equal(copilot.win, vim.api.nvim_get_current_win(), "claude -> copilot")
        lands(claude, stacked)
        lands(copilot, zen_spot)
        term.tile()
        assert.are.equal(claude.win, vim.api.nvim_get_current_win(), "copilot wraps to claude")
      end
    )

    it(
      "Given the floats are all in their grid spots with claude active, When <C-t> cycles focus to copilot, Then copilot becomes the active and selected harness",
      function()
        sw.init("claude")
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
        lands(claude, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
        term.tile()
        assert.are.equal(copilot.win, vim.api.nvim_get_current_win(), "focus cycles to copilot")
        assert.are.equal("copilot", sw.current(), "copilot is the active harness")
        assert.are.equal("copilot", require("harness-decorators.park").selected_harness(), "copilot is selected")
      end
    )

    it(
      "Given the floats are all in their grid spots in zen with claude focused, When <C-t> cycles to copilot, Then claude moves straight into the grid without stepping aside first",
      function()
        sw.init("claude")
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
        lands(claude, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
        term.tile()
        local anim = require("harness-decorators.terminal-animations")
        local orig, targets = anim.animate_resize, {}
        local real_is_open = zen_view.is_open
        zen_view.is_open = function()
          return true
        end
        -- Real Snacks focus can land a tick later than the call.
        function copilot:focus()
          vim.schedule(function()
            vim.api.nvim_set_current_win(self.win)
          end)
        end
        anim.animate_resize = function(i, rect, ...)
          if i == claude then
            table.insert(targets, vim.deepcopy(rect))
          end
          return orig(i, rect, ...)
        end
        term.tile()
        vim.wait(300)
        anim.animate_resize = orig
        zen_view.is_open = real_is_open
        for _, r in ipairs(targets) do
          assert.is_true(r.col <= 70, "claude was sent right of zen first: " .. vim.inspect(targets))
        end
        lands(claude, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
      end
    )

    it(
      "Given zen is open with claude focused and copilot in the grid, When <C-q> picks copilot and its focus lands a tick later, Then claude goes straight into the grid and copilot takes the zen spot",
      function()
        sw.init("claude")
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
        local anim = require("harness-decorators.terminal-animations")
        local orig, targets = anim.animate_resize, {}
        anim.animate_resize = function(i, rect, ...)
          if i == claude then
            table.insert(targets, vim.deepcopy(rect))
          end
          return orig(i, rect, ...)
        end
        local real_is_open = zen_view.is_open
        zen_view.is_open = function()
          return true
        end
        function copilot:focus()
          vim.schedule(function()
            vim.api.nvim_set_current_win(self.win)
          end)
        end
        sw.switch("copilot")
        sw.after_pick()
        vim.wait(300)
        anim.animate_resize = orig
        zen_view.is_open = real_is_open
        for _, r in ipairs(targets) do
          assert.is_true(r.col <= 70, "claude was sent right of zen: " .. vim.inspect(targets))
        end
        lands(claude, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
        lands(copilot, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
      end
    )

    it(
      "Given zen is open, the floats tiled and claude stepped aside while the <C-q> picker has focus, When copilot is picked, Then claude re-grids and copilot takes the zen spot",
      function()
        sw.init("claude")
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        vim.api.nvim_set_current_win(zen_win)
        lands(claude, { row = 0, col = 161, width = 19, height = math.floor(vim.o.lines * 0.90) })
        sw.switch("copilot")
        sw.after_pick()
        lands(claude, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
        lands(copilot, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
      end
    )

    it(
      "Given the floats are tiled but one was dragged out of its spot, When <C-t> is pressed, Then it re-grids without moving focus",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local stacked = { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) }
        lands(copilot, stacked)
        vim.wait(300)
        vim.api.nvim_win_set_config(copilot.win, { relative = "editor", row = 3, col = 5, width = 30, height = 8 })
        term.tile()
        assert.are.equal(claude.win, vim.api.nvim_get_current_win(), "focus must stay on claude")
        lands(copilot, stacked)
      end
    )

    it(
      "Given an unfocused harness float scrolled up, When its terminal gets new text, Then it scrolls to the last line",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        local lines = {}
        for n = 1, 100 do
          lines[n] = "line " .. n
        end
        vim.api.nvim_buf_set_lines(copilot.buf, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(copilot.win, { 1, 0 })
        vim.api.nvim_buf_set_lines(copilot.buf, -1, -1, false, { "new output" })
        assert.is_true(
          wait_for(function()
            return vim.api.nvim_win_get_cursor(copilot.win)[1] == 101
          end, 1000),
          "cursor at " .. vim.api.nvim_win_get_cursor(copilot.win)[1]
        )
      end
    )

    it("Given an unfocused harness float scrolled up, When tiling resizes it, Then it ends on the last line", function()
      local copilot = term.open("copilot")
      local claude = term.open("claude")
      vim.api.nvim_set_current_win(claude.win)
      local lines = {}
      for n = 1, 100 do
        lines[n] = "line " .. n
      end
      vim.api.nvim_buf_set_lines(copilot.buf, 0, -1, false, lines)
      vim.wait(200)
      vim.api.nvim_win_set_cursor(copilot.win, { 1, 0 })
      term.tile()
      lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
      assert.is_true(
        wait_for(function()
          return vim.api.nvim_win_get_cursor(copilot.win)[1] == 100
        end, 1000),
        "cursor at " .. vim.api.nvim_win_get_cursor(copilot.win)[1]
      )
    end)

    it(
      "Given a focused harness float scrolled up in normal mode, When its terminal gets new text, Then it stays where the user scrolled",
      function()
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        vim.cmd("stopinsert")
        local lines = {}
        for n = 1, 100 do
          lines[n] = "line " .. n
        end
        vim.api.nvim_buf_set_lines(claude.buf, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(claude.win, { 1, 0 })
        vim.api.nvim_buf_set_lines(claude.buf, -1, -1, false, { "new output" })
        vim.wait(300)
        assert.are.equal(1, vim.api.nvim_win_get_cursor(claude.win)[1])
      end
    )

    it(
      "Given zen is open with claude's float focused, When <C-q> picks copilot, Then grid mode turns on with copilot in the zen spot and claude in the grid",
      function()
        sw.init("claude")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        sw.switch("copilot")
        sw.after_pick()
        local copilot = state.table.copilot.inst
        assert.is_true(term._tiled == true, "grid mode must be on")
        lands(copilot, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
        lands(claude, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
      end
    )

    it(
      "Given zen is open and two harness floats with claude focused, When tiled, Then claude takes the zen spot and copilot takes the half of the empty area next to the zen window",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local tall = math.floor(vim.o.lines * 0.90)
        lands(claude, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
        lands(copilot, { row = 0, col = 20, width = 19, height = tall })
      end
    )

    it(
      "Given zen is open and three harness floats, When tiled, Then the two unfocused ones split the left column's height, ordered by name",
      function()
        local maki = term.open("maki")
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local tall = math.floor(vim.o.lines * 0.90)
        local top = math.floor(tall / 2)
        lands(copilot, { row = 0, col = 20, width = 19, height = top - 1 })
        lands(maki, { row = top, col = 20, width = 19, height = tall - top })
      end
    )

    it(
      "Given zen is open and four unfocused harness floats, When tiled, Then they sit two per row in two rows left of zen, ordered by name",
      function()
        local others = {}
        for _, h in ipairs({ "copilot", "crush", "maki", "pi" }) do
          others[h] = term.open(h)
        end
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local tall = math.floor(vim.o.lines * 0.90)
        local top = math.floor(tall / 2)
        lands(others.copilot, { row = 0, col = 0, width = 18, height = top - 1 })
        lands(others.crush, { row = 0, col = 19, width = 20, height = top - 1 })
        lands(others.maki, { row = top, col = 0, width = 18, height = tall - top })
        lands(others.pi, { row = top, col = 19, width = 20, height = tall - top })
      end
    )

    it(
      "Given zen is closed and four unfocused harness floats, When tiled, Then they sit two per row at the far right, left of the dock's space",
      function()
        zen_view.win = nil
        local others = {}
        for _, h in ipairs({ "copilot", "crush", "maki", "pi" }) do
          others[h] = term.open(h)
        end
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local tall = math.floor(vim.o.lines * 0.90)
        local top = math.floor(tall / 2)
        lands(others.copilot, { row = 0, col = 219, width = 29, height = top - 1 })
        lands(others.crush, { row = 0, col = 249, width = 30, height = top - 1 })
        lands(others.maki, { row = top, col = 219, width = 29, height = tall - top })
        lands(others.pi, { row = top, col = 249, width = 30, height = tall - top })
        lands(claude, { row = 0, col = 128, width = 90, height = tall })
      end
    )

    it(
      "Given zen is open and the floats are tiled with claude focused, When focus goes back to the zen window, Then claude steps aside right of zen and copilot stays in the grid",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        vim.api.nvim_set_current_win(zen_win)
        lands(claude, { row = 0, col = 161, width = 19, height = math.floor(vim.o.lines * 0.90) })
        lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
      end
    )

    it(
      "Given zen is open and three floats tiled with claude focused, When focus goes back to the zen window, Then claude steps aside at a grid cell's width and the grid's full height",
      function()
        term.open("maki")
        term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        vim.api.nvim_set_current_win(zen_win)
        lands(claude, { row = 0, col = 161, width = 19, height = math.floor(vim.o.lines * 0.90) })
      end
    )

    it(
      "Given a zen window leaving a gap narrower than a grid cell, When the tiled focused float steps aside, Then it keeps the cell width and the dock moves right of it",
      function()
        vim.api.nvim_win_set_config(zen_win, { relative = "editor", row = 0, col = 100, width = 120, height = 5 })
        term.open("maki")
        assert.is_true(term.minimize("maki"), "precondition: maki docked")
        term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        vim.api.nvim_set_current_win(zen_win)
        lands(claude, { row = 0, col = 221, width = 49, height = math.floor(vim.o.lines * 0.90) })
        assert.is_true(
          wait_for(function()
            local bar = bar_of("maki")
            return bar ~= nil and math.floor(vim.api.nvim_win_get_config(bar).col) == 270
          end, 1500),
          "the dock should start at claude's right edge (270): "
            .. vim.inspect(bar_of("maki") and vim.api.nvim_win_get_config(bar_of("maki")).col)
        )
      end
    )

    it(
      "Given zen is open and the floats are tiled with claude focused, When claude is minimized, reopened and focus goes back to the zen window, Then claude steps aside right of zen rather than into the grid",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        assert.is_true(term.minimize("claude"), "precondition: claude minimized")
        vim.wait(600)
        term.open("claude")
        assert.is_true(
          wait_for(function()
            return claude.win ~= nil
              and vim.api.nvim_win_is_valid(claude.win)
              and vim.api.nvim_get_current_win() == claude.win
          end, 1500),
          "precondition: claude reopened and focused"
        )
        vim.wait(300)
        vim.api.nvim_set_current_win(zen_win)
        lands(claude, { row = 0, col = 161, width = 19, height = math.floor(vim.o.lines * 0.90) })
        lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
      end
    )

    it(
      "Given zen is open and the floats are tiled, When a stacked float gets focus, Then it takes the zen spot and the previously focused one joins the stack",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        vim.api.nvim_set_current_win(copilot.win)
        lands(copilot, { row = 0, col = 70, width = 132, height = math.floor(vim.o.lines * 0.70) })
        lands(claude, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
      end
    )

    it(
      "Given zen is closed and two harness floats with claude focused, When tiled, Then copilot stacks at the far right before the dock's space and claude sits just left of it",
      function()
        zen_view.win = nil
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local tall = math.floor(vim.o.lines * 0.90)
        lands(copilot, { row = 0, col = 219, width = 60, height = tall })
        lands(claude, { row = 0, col = 128, width = 90, height = tall })
      end
    )

    it("Given the floats are tiled, When another harness is picked with <C-q>, Then tiling stays on", function()
      local copilot = term.open("copilot")
      local claude = term.open("claude")
      vim.api.nvim_set_current_win(claude.win)
      term.tile()
      require("harness-decorators.switch").switch("copilot")
      assert.is_true(term._tiled == true, "tiling must stay on")
      assert.is_true(copilot.win ~= nil and vim.api.nvim_win_is_valid(copilot.win), "copilot stays open")
    end)

    it(
      "Given zen is open with claude focused and copilot beside zen, When claude is minimized, Then focus leaves the harness floats and copilot keeps its unfocused spot",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.set_zen_width(true)
        vim.wait(600)
        local before = outer(copilot.win)
        assert.is_true(term.minimize("claude"), "precondition: claude minimized")
        vim.wait(600)
        assert.are_not.equal(copilot.win, vim.api.nvim_get_current_win(), "copilot must not get focus")
        assert.are.same(before, outer(copilot.win), "copilot must stay put")
      end
    )

    it(
      "Given the floats are tiled with claude focused, When claude is minimized, Then copilot stays in the stack",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        local stacked = { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) }
        lands(copilot, stacked)
        assert.is_true(term.minimize("claude"), "precondition: claude minimized")
        vim.wait(600)
        assert.are.same(stacked, outer(copilot.win), "copilot must stay in the stack")
      end
    )

    it(
      "Given the floats are tiled in zen, When reset_layout runs and a stacked float gets focus, Then the other float no longer moves left of zen",
      function()
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        vim.api.nvim_set_current_win(claude.win)
        term.tile()
        lands(copilot, { row = 0, col = 20, width = 19, height = math.floor(vim.o.lines * 0.90) })
        term.reset_layout()
        vim.api.nvim_set_current_win(copilot.win)
        vim.wait(600)
        assert.is_true(
          outer(claude.win).col > 39,
          "claude should stay right of zen: " .. vim.inspect(outer(claude.win))
        )
      end
    )
  end)
end)
