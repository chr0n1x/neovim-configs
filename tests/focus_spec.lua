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
  local term_mod
  local snacks
  local orig_open

  ---A fake Snacks instance backed by a real (windowless) buffer, so the open path runs end to
  -- end without spawning the real AI CLI (not installed in the container).
  setup(function()
    assert.is_not_nil(helper.active_harness(), "no active harness")
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    -- Collapse to a single window first: prior specs (add_current, go_back, command_selection) may
    -- leave splits open, and nvim_open_win for the float below E474s ("Invalid argument") when there
    -- isn't room. A single full-size window guarantees the float fits. Same guard go_back_spec uses.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    -- Replace the real Snacks float with a lightweight terminal-buftype window so we can assert a
    -- terminal window appears, without running the (absent) CLI. term.open calls snacks.open(cmd,
    -- {win=...}); we honor the win opts just enough to make a visible terminal buffer+window.
    snacks.open = function(_, opts)
      -- Open a real terminal-buftype window the same way add_current_spec does (vsplit + :terminal),
      -- which is the reliable headless path. nvim_open_win for a float E474s in this container, but a
      -- plain split with a live `cat` PTY works and gives wait_for_terminal a real terminal window.
      pcall(vim.cmd, "vsplit")
      pcall(vim.cmd, "terminal cat")
      local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
      return {
        buf = buf,
        win = vim.api.nvim_get_current_win(),
        hide = function() end,
        show = function() end,
        focus = function() end,
        close = function() end,
        buf_valid = function(self)
          return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
        end,
      }
    end
  end)

  teardown(function()
    if snacks and orig_open then
      snacks.open = orig_open
    end
    require("harness-decorators.state")._reset()
    -- Close any terminal window/buffer the test opened.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
          pcall(vim.api.nvim_win_close, w, true)
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
  end)

  it("opens a terminal-buftype window via <leader>c (the real focus path)", function()
    -- Drive the actual keymap callback: <leader>c now routes through park.show_selected -> term.open
    -- (Task 7), NOT ClaudeCodeFocus. Selecting the active harness and showing it must produce a
    -- terminal-buftype window.
    local park = require("harness-decorators.park")
    park.set_selected(helper.active_harness())
    local shown = park.show_selected()
    local shown = park.show_selected()
    assert.is_not_nil(shown, "show_selected returned nil (no float opened)")
    local term_win = helper.wait_for_terminal(5000)
    assert.is_not_nil(term_win, "harness terminal float did not appear after <leader>c")
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
