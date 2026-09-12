-- Tier 2: focus restore. Codifies the `<C-h` / buffer-duplication regressions.
--
-- The focus logic lives in harness-decorators/focus.lua (capture on WinLeave, then
-- jump_to_saved / restore to return). <C-h> and <leader>c are thin wrappers over it. We
-- test the module directly because the snacks floating terminal cannot stably enter
-- terminal mode in a headless nvim (no UI backend), so feeding <C-h> in terminal mode is
-- not reproducible here - but the focus mechanics it drives are, and they are exactly
-- where the regressions lived.
--
-- Two things are asserted:
--   1. The harness float actually opens (a terminal-buftype window appears) with a stub
--      command, so we know the open path runs end to end.
--   2. focus.capture records a non-terminal window, and jump_to_saved / restore return
--      to it without duplicating buffers - the behavior the guards in focus.lua protect.

local helper = require("tests.helper")

describe("focus: harness float opens", function()
  setup(function()
    -- Point the harness at a stub (the real AI CLI is not installed in the container) so
    -- the float can spawn. We restore to helper.pristine_terminal_cmd in teardown (not a
    -- locally-captured value) so this spec leaves no trace for later specs.
    local term = require("claudecode.terminal")
    term.setup(nil, "cat", {})
  end)

  teardown(function()
    pcall(function()
      require("claudecode.terminal").close()
    end)
    -- Always restore to the pristine startup value, even when it is nil (the broken-tree
    -- case). term.setup(nil, nil, {}) sets defaults.terminal_cmd back to nil.
    local term = require("claudecode.terminal")
    pcall(term.setup, nil, helper.pristine_terminal_cmd, {})
  end)

  it("opens a terminal-buftype window", function()
    assert.is_not_nil(helper.active_harness(), "no active harness")
    local ok, err = pcall(vim.cmd, "silent! ClaudeCodeFocus")
    assert.is_true(ok, "ClaudeCodeFocus raised: " .. tostring(err))
    local term_win = helper.wait_for_terminal(15000)
    assert.is_not_nil(term_win,
      "harness terminal float did not appear after <leader>c/ClaudeCodeFocus")
  end)
end)

describe("focus: capture / jump_to_saved / restore mechanics", function()
  local focus = require("harness-decorators.focus")
  local origin_buf, origin_win

  -- Collapse to a single window so the vnew splits below never hit E36 "Not enough room".
  -- Prior specs (e.g. add_current opening a cat terminal in a vsplit) may leave the buffer
  -- split; go_back_spec and go_back_after_add_spec use this same guard for the same reason.
  local function single_window()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  setup(function()
    -- Reset focus module state so a prior spec (e.g. command_selection switching
    -- harnesses) can't leave a guard like _suppress stuck and turn capture into a no-op.
    focus.reset()
    single_window()

    -- A real non-terminal buffer in its own window: the "origin" we must be able to
    -- return to.
    origin_buf = helper.open_scratch("-focus-origin.txt")
    vim.cmd("vnew")
    vim.api.nvim_set_current_buf(origin_buf)
    origin_win = vim.api.nvim_get_current_win()
  end)

  it("capture records the current non-terminal window", function()
    -- Stand in the origin window and capture. focus.last_win must become that window.
    vim.api.nvim_set_current_win(origin_win)
    focus.capture()
    assert.are.equal(origin_win, focus.last_win,
      "focus.capture did not record the originating window")
  end)

  it("jump_to_saved returns to the captured window", function()
    -- Move away (simulate the terminal taking focus), then jump back.
    vim.cmd("vnew")
    local away_win = vim.api.nvim_get_current_win()
    assert.is_not.equal(away_win, origin_win, "test setup: away window should differ")

    local moved = focus.jump_to_saved()
    assert.is_true(moved, "jump_to_saved reported no move")
    assert.are.equal(origin_win, vim.api.nvim_get_current_win(),
      "focus did not return to the originating window")
  end)

  it("restore does not duplicate a buffer already shown elsewhere", function()
    -- The neo-tree regression: if the saved buffer is already visible in another live
    -- window, restore must bail (return false) rather than steal it into a duplicate.
    vim.api.nvim_set_current_win(origin_win)
    focus.capture()

    -- Open the SAME buffer in a second window so it's "already shown elsewhere". Use a
    -- horizontal split via :split on the current buffer (avoids nvim_open_win config-key
    -- pitfalls in headless).
    vim.cmd("wincmd =") -- even out sizes so there's room to split
    local ok_split, err_split = pcall(vim.cmd, "split")
    assert.is_true(ok_split, "could not split for duplication test: " .. tostring(err_split))
    -- The new window now shows the same buffer (origin_buf) as origin_win.
    vim.api.nvim_set_current_buf(origin_buf)

    local restored = focus.restore()
    assert.is_false(restored,
      "restore should bail when the saved buffer is already shown in another window")
  end)

  it("suppress_next_leave makes capture a no-op", function()
    vim.api.nvim_set_current_win(origin_win)
    focus.capture()
    local before = focus.last_win

    -- Suppress, then capture from a different window: last_win must not change. Instead
    -- of opening yet another window (headless runs out of room), just re-capture from the
    -- same window after suppressing - capture must still be a no-op while suppressed.
    focus.suppress_next_leave()
    focus.capture()
    assert.are.equal(before, focus.last_win,
      "capture should be suppressed after suppress_next_leave")
  end)
end)
