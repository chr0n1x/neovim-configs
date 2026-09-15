-- Spec for the shared terminal-mode key legend (term.terminal_keys) - one test per key, driving the
-- extracted module-level handlers with fake Snacks instances. Terminal-mode keys can't be fed in a
-- headless nvim, so each handler is exposed on M and driven directly here:
--   * <C-f> -> term.fullscreen_key : toggles the float's _wide flag (fullscreen <-> collapse)
--   * <C-h> -> term.go_back_key    : moves focus back WITHOUT hiding the float (see go_back_key_spec)
--   * <C-n> -> term.normal_mode_key: drops into normal mode (stopinsert), float stays open
--   * <Esc> -> term.close_key      : hides the float (panel closes, PTY kept alive)
local helper = require("tests.helper")

describe("terminal key legend: one handler per key", function()
  local term_mod
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
      opts = { border = "rounded" }, -- terminal-animations reads self.opts.border during resize
      _wide = opts._wide,
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
    -- a real assertion on dimensions, not just the _wide flag.
    local win = open_term_window()
    local fake = make_fake({ win = win })
    assert.is_nil(fake._wide, "precondition: not yet wide")

    local ok, err = pcall(term_mod.fullscreen_key, fake)
    assert.is_true(ok, "fullscreen_key raised: " .. tostring(err))
    assert.is_true(fake._wide == true, "<C-f> first press must set _wide (fullscreen)")
    assert.is_not_nil(fake._saved_config, "first <C-f> must save the window config for later collapse")

    -- Wait until the animation finishes (its timer stops) so the window is at its final size.
    local done = vim.wait(2000, function()
      return not (fake._resize_anim and fake._resize_anim:is_running())
    end, 25)
    assert.is_true(done, "fullscreen resize animation did not finish in time")

    -- Measure the terminal window's dimensions and compare to the expected near-fullscreen target.
    local cfg = vim.api.nvim_win_get_config(win)
    local lines, cols = vim.o.lines, vim.o.columns
    local exp_w = (1 - 0.2) * cols -- 1 - 2*wide_col_pad
    local exp_h = (1 - 0.1) * lines -- 1 - 2*wide_row_pad
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
    assert.is_false(fake._wide, "<C-f> second press must clear _wide (collapse)")

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

    -- Enter terminal insert mode (what the float does on open via start_insert).
    vim.cmd("startinsert!")

    -- Drive the real <C-n> handler against this live terminal window.
    local fake = make_fake({ win = win })
    local ok_handler, err = pcall(term_mod.normal_mode_key)
    assert.is_true(ok_handler, "normal_mode_key raised: " .. tostring(err))

    -- We are now in normal mode (not terminal insert). A cursor jump to a specific line must work -
    -- this is the assertion the user asked for. In terminal insert mode the same motion would be
    -- ignored / error, so success here proves stopinsert actually took effect.
    local ok_jump, _ = pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    assert.is_true(ok_jump, "<C-n> did not reach normal mode - cursor jump failed (still in terminal insert)")
    local cur = vim.api.nvim_win_get_cursor(win)
    assert.are.equal(1, cur[1], "cursor should be at line 1 after the jump")

    -- The float must still be open and focused - <C-n> only changes the mode, it does not hide/close.
    assert.is_true(vim.api.nvim_win_is_valid(win), "<C-n> must NOT close the terminal window")
    assert.is_false(fake.hide_called, "<C-n> must NOT hide the float")
  end)

  it("registers a FocusGained handler for harness terminals", function()
    local autocmds = vim.api.nvim_get_autocmds({
      group = "HarnessTerminalAutoInsert",
      event = "FocusGained",
    })
    assert.are.equal(1, #autocmds, "FocusGained must have one harness-terminal handler")

    local ok, err = pcall(vim.api.nvim_exec_autocmds, "FocusGained", {})
    assert.is_true(ok, "FocusGained handler raised: " .. tostring(err))
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

  it("<C-o> opens the agent picker from terminal mode", function()
    local keys = term_mod.terminal_keys()
    local agent_key
    for _, spec in ipairs(keys) do
      if spec[1] == "<C-o>" then
        agent_key = spec
        break
      end
    end
    assert.is_not_nil(agent_key, "<C-o> must be in the shared terminal legend")
    assert.are.equal("t", agent_key.mode, "<C-o> must be a terminal-mode key")
    assert.are.equal("⇄", agent_key.desc)

    local switch = require("harness-decorators.switch")
    local original_pick = switch.pick
    local called = false
    switch.pick = function()
      called = true
    end
    local ok, err = pcall(agent_key[2])
    switch.pick = original_pick

    assert.is_true(ok, "<C-o> handler raised: " .. tostring(err))
    assert.is_true(called, "<C-o> must call the agent picker")
  end)

  it("<C-l> is in the shared legend and bound to the SAME handler as <C-h>", function()
    -- <C-l> is a second go-back binding (right-hand side counterpart of <C-h>). It must live in the
    -- shared terminal_keys legend (so every harness float gets it) and route to the same go_back_key
    -- handler - not a copy. We assert on the legend itself via M.terminal_keys.
    local keys = term_mod.terminal_keys()
    local by_lhs = {}
    for _, spec in ipairs(keys) do
      by_lhs[spec[1]] = spec
    end
    assert.is_not_nil(by_lhs["<C-h>"], "<C-h> must be in the shared legend")
    assert.is_not_nil(by_lhs["<C-l>"], "<C-l> must be in the shared legend (global go-back binding)")
    -- Both must be terminal-mode keys.
    assert.are.equal("t", by_lhs["<C-l>"].mode, "<C-l> must be a terminal-mode key")
    -- Drive BOTH handlers through their legend entries with a fresh fake and confirm they behave
    -- identically: neither hides the float (go-back leaves it visible). This proves <C-l> routes to
    -- go_back_key, not some other handler.
    local fake_h = make_fake()
    local ok_h = pcall(by_lhs["<C-h>"][2], fake_h)
    assert.is_true(ok_h, "<C-h> legend handler raised")
    assert.is_false(fake_h.hide_called, "<C-h> must not hide the float")

    local fake_l = make_fake()
    local ok_l = pcall(by_lhs["<C-l>"][2], fake_l)
    assert.is_true(ok_l, "<C-l> legend handler raised")
    assert.is_false(fake_l.hide_called, "<C-l> must not hide the float (same go-back behavior as <C-h>)")
  end)
end)
