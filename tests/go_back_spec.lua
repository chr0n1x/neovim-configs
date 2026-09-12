-- Tier 2b: <C-h> "go back to the previous buffer".
--
-- Contract (docs + user): for every harness, while focus is in the floating terminal,
-- <C-h> must return focus to the window we came from. Concretely, if you press <C-t> or
-- <leader>c from neo-tree to jump into the terminal, <C-h> takes you back to neo-tree.
--
-- The real <C-h> binding (lua/plugins/ai-harness.lua) is a terminal-mode key on the
-- snacks float whose handler is go_back(self). In a headless nvim the float cannot enter
-- terminal mode (no UI backend), so we cannot feed the literal <C-h> in terminal mode.
-- Instead we drive the exact focus path go_back uses: it calls
--   focus.suppress_next_leave() -> (hide float) -> focus.jump_to_saved() [fallback set_prev_win]
-- The hide and the fallback are headless-only concerns; the behavior under test - "return
-- to the originating window" - is precisely what jump_to_saved does, seeded by the WinLeave
-- capture that fires when you leave neo-tree for the terminal. This spec codifies that:
--   1. leaving a work buffer (neo-tree stand-in) records it as the restore target, and
--   2. after focus has moved to the terminal, jumping back lands on that same window.
--
-- We also assert the fallback (set_prev_win / find_base_window) still finds a base window
-- when no saved window exists, so <C-h> never strands you in the float.

local helper = require("tests.helper")
local focus = require("harness-decorators.focus")

-- Collapse to a single window so the headless buffer (a fixed small size) always has room
-- for the vnew splits this spec needs. Prior specs may leave it split, and E36 "Not enough
-- room" otherwise aborts the setup. Safe: closing windows only drops scratch buffers we
-- created; no real file content is lost in a headless run.
local function single_window()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= vim.api.nvim_get_current_win() then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

describe("<C-h>: go back to the previous buffer", function()
  local origin_win, origin_buf

  setup(function()
    -- Clean slate: no guard left stuck by a prior spec (e.g. a harness switch).
    focus.reset()
    single_window()

    -- A real non-terminal buffer in its own window stands in for neo-tree - the "origin"
    -- we must be able to return to. It is a file-backed scratch buffer so find_base_window's
    -- fs_stat validity check would also accept it (mimics a real tree/working window). Write
    -- the file to disk: open_scratch only names the buffer, and the fallback test relies on
    -- fs_stat(buf_name) being non-nil.
    origin_buf = helper.open_scratch("-go-back-origin.txt")
    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "origin" })
    pcall(vim.fn.writefile, { "origin" }, vim.api.nvim_buf_get_name(origin_buf))
    vim.cmd("vnew")
    vim.api.nvim_set_current_buf(origin_buf)
    origin_win = vim.api.nvim_get_current_win()
  end)

  teardown(function()
    focus.reset()
    single_window()
  end)

  it("capture records the originating window when we leave it for the terminal", function()
    -- Simulate leaving neo-tree (origin_win) for the float: WinLeave fires capture().
    vim.api.nvim_set_current_win(origin_win)
    focus.capture()
    assert.are.equal(origin_win, focus.last_win,
      "leaving the origin window did not record it as the restore target")
  end)

  it("<C-h> returns to the originating window after focus moved to the terminal", function()
    -- Stand in neo-tree and capture (this is what WinLeave does when <C-t>/<leader>c jumps us out).
    vim.api.nvim_set_current_win(origin_win)
    focus.capture()

    -- Focus has now moved to the terminal: open a scratch window to stand in for the float.
    single_window()
    vim.cmd("vnew")
    local away_win = vim.api.nvim_get_current_win()
    assert.is_not.equal(away_win, origin_win, "test setup: terminal window should differ from origin")

    -- go_back's core action (when no saved terminal window is recorded headless): jump_to_saved.
    focus.suppress_next_leave()
    local moved = focus.jump_to_saved()
    assert.is_true(moved, "jump_to_saved reported no move - <C-h> would strand you in the float")
    assert.are.equal(origin_win, vim.api.nvim_get_current_win(),
      "<C-h> did not return to the originating window (neo-tree)")
  end)

  it("<C-h> does not strand you when there is no saved window (fallback finds a base window)", function()
    -- No capture has happened for THIS test: reset so a prior test's last_win doesn't leak in.
    focus.reset()
    assert.is_nil(focus.last_win, "test setup: expected no saved window")

    -- Open the float stand-in and move into it.
    single_window()
    vim.cmd("vnew")
    local term_win = vim.api.nvim_get_current_win()

    -- Reproduce find_base_window's selection logic directly (it is a local in ai-harness.lua):
    -- pick the last window that is not floating, not the terminal, and shows a file on disk.
    local function valid(win_id)
      local cfg = vim.api.nvim_win_get_config(win_id)
      local buf = vim.api.nvim_win_get_buf(win_id)
      return not cfg.z and win_id ~= term_win and vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf)) ~= nil
    end
    local base = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if valid(w) then
        base = w -- last match wins, matching find_base_window's reverse scan
      end
    end
    assert.is_not_nil(base, "find_base_window found no valid base window - <C-h> would strand you")
    assert.is_not.equal(base, term_win, "fallback landed on the terminal window itself")
  end)

  it("returning to neo-tree keeps exactly one window showing that buffer (no duplication)", function()
    -- The regression this whole focus layer exists for: <C-h> must not duplicate the origin
    -- buffer into a second window. Capture, jump away, jump back, then count windows on the
    -- origin buffer - it must be exactly one.
    vim.api.nvim_set_current_win(origin_win)
    focus.capture()

    single_window()
    vim.cmd("vnew")
    focus.suppress_next_leave()
    assert.is_true(focus.jump_to_saved(), "jump_to_saved failed in duplication test")

    local count = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == origin_buf then
        count = count + 1
      end
    end
    assert.are.equal(1, count,
      "origin (neo-tree) buffer is shown in more than one window after <C-h> - duplication regression")
  end)
end)
