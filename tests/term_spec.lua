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

  it("show(harness) RE-FOCUSES an already-open window via :focus(), not :show() (regression: <leader>c after <C-h>)", function()
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
  end)

  it("show(harness) enters terminal INSERT mode on a re-focus (selecting a harness = typing)", function()
    -- The bug: after <C-h> (or any re-select), focus returns to the float in NORMAL mode. Snacks only
    -- enters insert on a fresh open, so a pure :focus() leaves you staring at a normal-mode prompt -
    -- selecting a harness should land you typing. focus_instance must call startinsert itself when the
    -- instance has a live buffer. (A truly headless nvim cannot actually enter terminal insert - no UI -
    -- so we assert on the startinsert CALL, not vim.fn.mode().) We stand in for the float with a real
    -- terminal window (vsplit + :terminal cat - the reliable headless path).
    local term = require("harness-decorators.term")
    term._reset()
    local inst = term.open("claude")

    -- Collapse to a single window so the vsplit below has room, then open a real terminal there.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    vim.wait(100, function() return false end, 25)

    inst.buf = vim.api.nvim_win_get_buf(win)
    inst.win = win
    inst.focus = function()
      vim.api.nvim_set_current_win(win)
    end

    -- Spy on startinsert: focus_instance must invoke it for a live terminal buffer.
    local orig_startinsert = vim.cmd.startinsert
    local insert_calls = 0
    vim.cmd.startinsert = function(...)
      insert_calls = insert_calls + 1
      return orig_startinsert(...)
    end

    term.show("claude")
    -- Insert is deferred to the next tick (see enter_insert_scheduled) so it sticks; flush before asserting.
    vim.wait(200, function()
      return insert_calls > 0
    end, 10)
    assert.is_true(insert_calls > 0, "show(claude) must enter terminal insert mode (startinsert not called)")

    vim.cmd.startinsert = orig_startinsert
    pcall(vim.cmd.stopinsert)
    local term_buf = inst.buf
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
  end)

  it("show_selected (the <leader>cl picker path) enters INSERT mode on a fresh open", function()
    -- The reported bug: picking a harness from the <leader>cl picker did not land in insert mode. That
    -- path is switch.after_pick -> park.show_selected -> term.open, which for a never-opened harness is a
    -- FRESH Snacks.open (not a re-focus). Snacks' start_insert only fires in on_win and can be skipped if
    -- focus is already on the terminal window (the picker has no focus.restore() to move it away first), so
    -- term.open must enter insert itself. We stub Snacks.open to return a fake backed by a real terminal
    -- buffer and assert startinsert is called for the fresh-open branch.
    local term = require("harness-decorators.term")
    local park = require("harness-decorators.park")
    term._reset()

    -- A real terminal buffer to back the fake (startinsert needs a valid buffer).
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    vim.wait(100, function() return false end, 25)
    local term_buf = vim.api.nvim_win_get_buf(win)

    -- Stub Snacks.open to hand back a fake instance backed by that real terminal buffer.
    local orig_open = snacks.open
    snacks.open = function()
      return {
        buf = term_buf,
        win = win,
        hide = function() end,
        show = function() end,
        focus = function() end,
        close = function() end,
        buf_valid = function(self)
          return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
        end,
      }
    end

    local orig_startinsert = vim.cmd.startinsert
    local insert_calls = 0
    vim.cmd.startinsert = function(...)
      insert_calls = insert_calls + 1
      return orig_startinsert(...)
    end

    park.set_selected("claude")
    local shown = park.show_selected()
    assert.are.equal("claude", shown, "show_selected must open the selected harness")
    -- The fresh-open insert is deferred to the next tick (see enter_insert_scheduled), so flush the
    -- schedule before asserting it ran.
    vim.wait(200, function()
      return insert_calls > 0
    end, 10)
    assert.is_true(insert_calls > 0, "picker path (show_selected -> fresh open) must enter terminal insert mode")

    vim.cmd.startinsert = orig_startinsert
    snacks.open = orig_open
    pcall(vim.cmd.stopinsert)
    term._reset()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
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

  it("open(already-live harness) enters terminal INSERT mode on a re-show (swap between terminals)", function()
    -- The bug: swapping between two already-running terminals (claude -> maki -> claude) is a RE-SHOW of
    -- an existing live instance, which goes through term.open's is_live branch. That branch called
    -- enter_insert SYNCHRONOUSLY right after focus_instance - the same unreliable pattern the fresh-open
    -- path already fixed by deferring to the next tick (a synchronous startinsert before the window/buffer
    -- settle does not stick, leaving you in "-- (terminal) --" normal mode instead of "-- TERMINAL --").
    -- The re-show path must use the SAME deferred insert as fresh open. We assert the distinguishing
    -- property: immediately after term.open returns, startinsert has NOT yet run synchronously - it is
    -- scheduled for the next tick (then we flush and confirm it did run).
    local term = require("harness-decorators.term")
    term._reset()

    -- Stand in for the float with a real terminal window (the reliable headless path).
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    vim.wait(100, function() return false end, 25)
    local term_buf = vim.api.nvim_win_get_buf(win)

    -- First open: make the stored instance back onto this real terminal buffer so it reads as live.
    local inst = term.open("claude")
    inst.buf = term_buf
    inst.win = win
    inst.focus = function()
      vim.api.nvim_set_current_win(win)
    end

    -- Drop out of insert so the re-show has to put us back in (mirrors a parked/normal-mode panel).
    pcall(vim.cmd.stopinsert)

    -- Spy on startinsert: the second open (a re-show) must schedule it, not run it synchronously.
    local orig_startinsert = vim.cmd.startinsert
    local insert_calls = 0
    vim.cmd.startinsert = function(...)
      insert_calls = insert_calls + 1
      return orig_startinsert(...)
    end

    -- Second open of the same live harness: this is the swap-between-terminals re-show path.
    term.open("claude")
    assert.are.equal(0, insert_calls, "re-show must NOT enter insert synchronously (it would not stick)")
    -- The deferred (scheduled) insert lands on the next tick; flush it and confirm it ran.
    vim.wait(200, function()
      return insert_calls > 0
    end, 10)
    assert.is_true(insert_calls > 0, "re-showing an already-live harness must enter terminal insert mode (deferred)")

    vim.cmd.startinsert = orig_startinsert
    pcall(vim.cmd.stopinsert)
    term._reset()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
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

  it("list() does NOT delete a selected-but-never-opened harness entry (regression: <leader>c dead after opening the picker)", function()
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
    assert.is_not_nil(require("harness-decorators.state").table["claude"], "list() must not delete a selected-but-never-opened entry")
    assert.are.equal("claude", park.selected_harness(), "selection must survive the picker's list() call")

    -- The downstream effect: show_selected can still open claude (it is still selected).
    local shown = park.show_selected()
    assert.are.equal("claude", shown, "show_selected must still open claude after the picker ran list()")
    term._reset()
  end)

  it("list() DOES drop a harness whose instance exited (dead buffer)", function()
    -- The other half of the contract: a harness that WAS opened and whose process has now exited
    -- (buffer wiped) is genuinely dead and must be removed so the picker never offers it. This keeps
    -- the original cleanup behavior intact - we only stopped culling the never-opened case above.
    local term = require("harness-decorators.term")
    term._reset()

    local inst = term.open("claude")
    assert.is_not_nil(require("harness-decorators.state").table["claude"], "precondition: claude record exists after open")

    -- Simulate the process exiting: wipe the buffer so buf_valid() is false.
    pcall(vim.api.nvim_buf_delete, inst.buf, { force = true })
    local entries = term.list()
    assert.are.equal(0, #entries, "an exited harness must not be listed")
    assert.is_nil(require("harness-decorators.state").table["claude"], "list() must drop an entry whose instance exited")
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
