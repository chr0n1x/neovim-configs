-- <C-h> after <leader>ca. Codifies the "go back to where I pressed <leader>ca from"
-- regression. Repro: in neotree press <C-t> (to the terminal), <C-h> (back to neotree), tmux
-- <C-l> (to the file buffer), <leader>ca (to the terminal), then <C-h> must land on the FILE
-- buffer, not neotree.
--
-- The regression: focus.capture() records a window as the restore target on WinLeave, and its
-- _skip_buf guard (skip a window showing the buffer captured last; jump_to_saved leaves it
-- set) must not stop it from recording the file buffer once neotree is captured. If it did,
-- <leader>ca and then <C-h> would return to the stale neotree.
--
-- We model the exact window transitions with real windows (neo-tree and file stand-ins) and
-- drive the real focus module, asserting last_win tracks the most-recent non-terminal window
-- we left - which is what <C-h> must return to.

local helper = require("tests.helper")
local focus = require("harness-decorators.focus")

-- Collapse to a single window so vnew splits never hit E36 in the small headless buffer.
local function single_window()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= vim.api.nvim_get_current_win() then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

describe("<C-h> after <leader>ca: returns to the buffer <leader>ca was pressed from", function()
  local tree_buf, tree_win, file_buf, file_win

  setup(function()
    focus.reset()
    single_window()

    -- neo-tree stand-in: a real file-backed buffer in its own window.
    tree_buf = helper.open_scratch("-go-back-tree.txt")
    vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, { "tree" })
    pcall(vim.fn.writefile, { "tree" }, vim.api.nvim_buf_get_name(tree_buf))
    vim.cmd("vnew")
    vim.api.nvim_set_current_buf(tree_buf)
    tree_win = vim.api.nvim_get_current_win()

    -- file-buffer stand-in: a second real file-backed buffer in its own window.
    file_buf = helper.open_scratch("-go-back-file.txt")
    vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { "file" })
    pcall(vim.fn.writefile, { "file" }, vim.api.nvim_buf_get_name(file_buf))
    vim.cmd("vnew")
    vim.api.nvim_set_current_buf(file_buf)
    file_win = vim.api.nvim_get_current_win()
  end)

  teardown(function()
    focus.reset()
    single_window()
  end)

  it("<C-h> after <leader>ca returns to the file buffer, not neo-tree", function()
    -- Step 1: start in neo-tree.
    vim.api.nvim_set_current_win(tree_win)

    -- Step 2: <C-t> jumps to the terminal. WinLeave fires and capture records neo-tree.
    focus.capture()
    assert.are.equal(tree_win, focus.last_win, "step 2: capture should record neo-tree")

    -- Step 3: <C-h> goes back to neo-tree (jump_to_saved). _suppress is set; leaving the
    -- terminal window is skipped by capture. last_win stays neo-tree.
    assert.is_true(focus.jump_to_saved(), "step 3: jump_to_saved failed")
    assert.are.equal(tree_win, vim.api.nvim_get_current_win(), "step 3: should be back in neo-tree")

    -- Step 4: tmux <C-l> moves focus to the file buffer (a different window). WinLeave fires
    -- and capture MUST record the file buffer as the new restore target.
    vim.api.nvim_set_current_win(file_win)
    focus.capture()
    assert.are.equal(
      file_win,
      focus.last_win,
      "step 4: after <C-l> to the file buffer, capture did not re-record it - last_win is stale"
    )

    -- Step 5: <leader>ca jumps to the terminal. It just moves focus (focus.restore and
    -- suppress are for <leader>c), so the WinLeave capture records the file buffer we are in.
    vim.api.nvim_set_current_win(file_win)
    focus.capture()

    -- Step 6: <C-h> must return to the FILE buffer (where <leader>ca was pressed from).
    assert.is_true(focus.jump_to_saved(), "step 6: jump_to_saved failed")
    assert.are.equal(
      file_win,
      vim.api.nvim_get_current_win(),
      "<C-h> after <leader>ca returned to neo-tree instead of the file buffer"
    )
  end)
end)
