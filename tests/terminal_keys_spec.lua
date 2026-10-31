-- Spec for the shared terminal-mode key legend (term.terminal_keys) - one test per key, driving the
-- module-level handlers with fake Snacks instances. Terminal-mode keys can't be fed in a headless
-- nvim, so each handler is exposed on M and driven directly here:
--   * <C-f>, term.fullscreen_key: toggles the float between fullscreen and its saved size
--   * <C-h>, term.go_back_key: moves focus back WITHOUT hiding the float (see go_back_key_spec)
--   * <C-n>, term.normal_mode_key: drops into normal mode (stopinsert), float stays open
--   * <Esc>, term.close_key: minimizes the float (here it hides it, since the fakes have no window)
local helper = require("tests.helper")

describe("terminal key legend: one handler per key", function()
  local term_mod
  local layout
  local focus
  local original_harness
  local orig_env

  ---A fake Snacks instance backed by a real windowless buffer. Records hide/show calls so specs can
  -- assert on them. `win` is nil by default (fullscreen_key bails cleanly without a valid window).
  local function make_fake(opts)
    opts = opts or {}
    local inst = {
      buf = vim.api.nvim_create_buf(false, true),
      win = opts.win,
      opts = { border = "rounded" }, -- harness-decorators/terminal-animations reads self.opts.border during resize
      _saved_config = opts._saved_config,
      hide_called = false,
      show_called = false,
    }
    -- Capture `inst` rather than `self`: handlers may call inst:hide() via pcall(function() ... end),
    -- where the closure runs with no argument and a `function(self)` body would see self == nil.
    inst.hide = function()
      inst.hide_called = true
    end
    inst.show = function()
      inst.show_called = true
    end
    inst.focus = function() end
    inst.close = function() end
    return inst
  end

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness")
    orig_env = os.getenv("NVIM_LLM_HARNESS")
    term_mod = require("harness-decorators.term")
    layout = require("harness-decorators.layout")
    focus = require("harness-decorators.focus")
    focus.reset()
  end)

  teardown(function()
    focus.reset()
    -- Close any terminal window/buffer this describe opened (the <C-n> test opens a real `cat` PTY in a
    -- vsplit) so it doesn't leak into later specs. Also drop terminal insert mode if we left it on.
    pcall(vim.cmd, "stopinsert")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
  end)

  ---Open a real terminal window the reliable headless way (vsplit + :terminal cat). Returns the
  -- window id. We use a live terminal buffer (not nvim_open_win for a float, which E474s in this
  -- container) so animate_resize has a real window to measure against.
  local function open_term_window()
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    vim.wait(100, function()
      return false
    end, 25)
    return win
  end

  it("<C-f> fullscreen_key: first press widens the window to near-fullscreen", function()
    -- Trigger <C-f> on a real terminal window, let the resize animation actually run (it ticks on a
    -- ~300ms timer), then MEASURE the resulting window geometry. The target is 5% vertical / 10%
    -- horizontal padding from the editor edges, so the measured width/height must be close to that -
    -- a real assertion on dimensions, not just the layout.
    local win = open_term_window()
    local fake = make_fake({ win = win })
    assert.are.equal("normal", layout.get(fake), "precondition: not yet wide")

    local ok, err = pcall(term_mod.fullscreen_key, fake)
    assert.is_true(ok, "fullscreen_key raised: " .. tostring(err))
    assert.are.equal("fullscreen", layout.get(fake), "<C-f> first press must go fullscreen")
    assert.is_not_nil(fake._saved_config, "first <C-f> must save the window geometry (as ratios) for later collapse")

    -- Wait until the animation finishes (its timer stops) so the window is at its final size.
    local done = vim.wait(2000, function()
      return not (fake._resize_anim and fake._resize_anim:is_running())
    end, 25)
    assert.is_true(done, "fullscreen resize animation did not finish in time")

    -- Measure the terminal window's dimensions and compare to the expected near-fullscreen target.
    local cfg = vim.api.nvim_win_get_config(win)
    local lines, cols = vim.o.lines, vim.o.columns
    local exp_w = (1 - 0.2) * cols -- 1 - 2 * layout.FULL_COL_PAD
    local exp_h = (1 - 0.1) * lines -- 1 - 2 * layout.FULL_ROW_PAD
    assert.is_true(
      cfg.width >= math.floor(exp_w) - 1 and cfg.width <= math.ceil(exp_w) + 1,
      string.format("<C-f> fullscreen width %d not near expected ~%d", cfg.width or -1, exp_w)
    )
    assert.is_true(
      cfg.height >= math.floor(exp_h) - 1 and cfg.height <= math.ceil(exp_h) + 1,
      string.format("<C-f> fullscreen height %d not near expected ~%d", cfg.height or -1, exp_h)
    )
    -- It must be a float now (the animation re-parents the window relative to the editor).
    assert.is_true(cfg.relative == "editor", "<C-f> fullscreen must reposition the window as an editor-relative float")
  end)

  it("<C-f> fullscreen_key: second press collapses back to the saved size", function()
    -- Widen first, measure the wide size, then <C-f> again and measure that it returns to the saved
    -- (non-fullscreen) dimensions. This proves the toggle is symmetric on real geometry.
    local win = open_term_window()
    local fake = make_fake({ win = win })

    pcall(term_mod.fullscreen_key, fake)
    vim.wait(2000, function()
      return not (fake._resize_anim and fake._resize_anim:is_running())
    end, 25)
    local wide_cfg = vim.api.nvim_win_get_config(win)

    -- Second press collapses back to the saved config.
    local ok, err = pcall(term_mod.fullscreen_key, fake)
    assert.is_true(ok, "fullscreen_key (collapse) raised: " .. tostring(err))
    assert.are.equal("normal", layout.get(fake), "<C-f> second press must collapse")

    vim.wait(2000, function()
      return not (fake._resize_anim and fake._resize_anim:is_running())
    end, 25)
    local collapsed_cfg = vim.api.nvim_win_get_config(win)

    -- After collapse the window should be back to roughly the saved size - clearly smaller than the
    -- fullscreen width we measured. (The saved config was a plain split, so its width is ~half.)
    assert.is_true(
      collapsed_cfg.width < wide_cfg.width,
      string.format(
        "collapse did not shrink the window: collapsed %d >= wide %d",
        collapsed_cfg.width or -1,
        wide_cfg.width or -1
      )
    )
  end)

  it("<C-h> go_back_key: moves focus back WITHOUT hiding the float", function()
    -- The "go back" key must leave the panel visible. Assert hide is never called.
    local fake = make_fake()
    local ok, err = pcall(term_mod.go_back_key, fake)
    assert.is_true(ok, "go_back_key raised: " .. tostring(err))
    assert.is_false(fake.hide_called, "<C-h> must NOT hide the float - it stays visible")
  end)

  it("<C-n> normal_mode_key: drops into normal mode (cursor becomes movable)", function()
    -- Open a real terminal window the reliable headless way (vsplit + :terminal cat), enter its
    -- terminal insert mode, then run the <C-n> handler. The proof that it reached NORMAL mode is
    -- behavioral: in terminal insert mode you cannot move the cursor with normal! motions, but in
    -- normal mode you can - so jumping the cursor to a specific line only succeeds after <C-n>.
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    -- Give the buffer a moment to register its buftype before we enter insert mode.
    vim.wait(100, function()
      return false
    end, 25)

    -- Enter terminal insert mode (what schedule_enter_terminal_mode does when the float opens).
    vim.cmd("startinsert!")

    -- Drive the real <C-n> handler against this live terminal window.
    local fake = make_fake({ win = win })
    local ok_handler, err = pcall(term_mod.normal_mode_key)
    assert.is_true(ok_handler, "normal_mode_key raised: " .. tostring(err))

    -- In normal mode a cursor jump to a specific line works; in terminal insert mode the same
    -- motion would be ignored or error, so success here proves stopinsert took effect.
    local ok_jump, _ = pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    assert.is_true(ok_jump, "<C-n> did not reach normal mode - cursor jump failed (still in terminal insert)")
    local cur = vim.api.nvim_win_get_cursor(win)
    assert.are.equal(1, cur[1], "cursor should be at line 1 after the jump")

    -- The float must still be open and focused - <C-n> only changes the mode, it does not hide/close.
    assert.is_true(vim.api.nvim_win_is_valid(win), "<C-n> must NOT close the terminal window")
    assert.is_false(fake.hide_called, "<C-n> must NOT hide the float")
  end)

  it("registers a FocusGained handler for harness terminals", function()
    for _, event in ipairs({ "FocusGained" }) do
      local autocmds = vim.api.nvim_get_autocmds({
        group = "HarnessTerminalAutoInsert",
        event = event,
      })
      assert.are.equal(1, #autocmds, event .. " must have one harness-terminal handler")

      local ok, err = pcall(vim.api.nvim_exec_autocmds, event, {})
      assert.is_true(ok, event .. " handler raised: " .. tostring(err))
    end
  end)

  it("<Esc> close_key: hides the float (panel closes)", function()
    -- <Esc> is the close key: it MUST hide the instance (the PTY stays alive underneath).
    local fake = make_fake()
    local ok, err = pcall(term_mod.close_key, fake)
    assert.is_true(ok, "close_key raised: " .. tostring(err))
    assert.is_true(fake.hide_called, "<Esc> must hide the float - that is what 'close' means here")
  end)

  it("<C-p> opens the procs picker from terminal mode", function()
    local keys = term_mod.terminal_keys()
    local procs_key
    for _, spec in ipairs(keys) do
      if spec[1] == "<C-p>" then
        procs_key = spec
        break
      end
    end
    assert.is_not_nil(procs_key, "<C-p> must be in the shared terminal legend")
    assert.are.equal("t", procs_key.mode, "<C-p> must be a terminal-mode key")
    assert.are.equal("⚙", procs_key.desc)

    local procs = require("util.procs")
    local original_pick = procs.pick
    local called = false
    procs.pick = function()
      called = true
    end
    local ok, err = pcall(procs_key[2])
    procs.pick = original_pick

    assert.is_true(ok, "<C-p> handler raised: " .. tostring(err))
    assert.is_true(called, "<C-p> must call the procs picker")
  end)

  it("<C-q> opens the agent picker from terminal mode", function()
    local keys = term_mod.terminal_keys()
    local agent_key
    for _, spec in ipairs(keys) do
      if spec[1] == "<C-q>" then
        agent_key = spec
        break
      end
    end
    assert.is_not_nil(agent_key, "<C-q> must be in the shared terminal legend")
    assert.are.equal("t", agent_key.mode, "<C-q> must be a terminal-mode key")
    assert.are.equal("⇄", agent_key.desc)

    local switch = require("harness-decorators.switch")
    local original_pick = switch.pick
    local called = false
    switch.pick = function()
      called = true
    end
    local ok, err = pcall(agent_key[2])
    switch.pick = original_pick

    assert.is_true(ok, "<C-q> handler raised: " .. tostring(err))
    assert.is_true(called, "<C-q> must call the agent picker")
  end)

  it("Given the shared legend, Then <C-l> is a terminal-mode key bound to the shelf toggle", function()
    local by_lhs = {}
    for _, spec in ipairs(term_mod.terminal_keys()) do
      by_lhs[spec[1]] = spec
    end
    assert.is_not_nil(by_lhs["<C-l>"], "<C-l> must be in the shared legend")
    assert.are.equal("t", by_lhs["<C-l>"].mode, "<C-l> must be a terminal-mode key")
    local orig, got = term_mod.shelf_key, nil
    term_mod.shelf_key = function(self)
      got = self
    end
    local fake = make_fake()
    local ok, err = pcall(by_lhs["<C-l>"][2], fake)
    term_mod.shelf_key = orig
    assert.is_true(ok, "<C-l> legend handler raised: " .. tostring(err))
    assert.are.equal(fake, got, "<C-l> must call shelf_key with the instance")
  end)

  it("Given the shared legend, Then <C-t> is a terminal-mode key bound to the tiling readjust", function()
    local by_lhs = {}
    for _, spec in ipairs(term_mod.terminal_keys()) do
      by_lhs[spec[1]] = spec
    end
    assert.is_not_nil(by_lhs["<C-t>"], "<C-t> must be in the shared legend")
    assert.are.equal("t", by_lhs["<C-t>"].mode, "<C-t> must be a terminal-mode key")
    local orig, called = term_mod.tile, false
    term_mod.tile = function()
      called = true
    end
    local ok, err = pcall(by_lhs["<C-t>"][2], make_fake())
    term_mod.tile = orig
    assert.is_true(ok, "<C-t> legend handler raised: " .. tostring(err))
    assert.is_true(called, "<C-t> must call term.tile")
  end)
end)
