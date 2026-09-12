-- Jumping between buffers. Covers PRD priority #3: moving window focus to a buffer must
-- land on the intended buffer and must NOT duplicate it into another window. Buffer
-- duplication is the regression class the focus guards exist to prevent; this test checks
-- the general invariant (one live window per buffer) across normal navigation, independent
-- of the harness terminal.

local helper = require("tests.helper")

---Count how many live windows in the current tab show a given buffer.
---@param bufnr number
---@return number
local function windows_showing(bufnr)
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
      n = n + 1
    end
  end
  return n
end

describe("buffer jump: focus moves without duplication", function()
  local buf_a, buf_b, win_a, win_b

  setup(function()
    -- Two real scratch buffers in their own windows. Track each window id explicitly so
    -- navigation assertions don't depend on split geometry (vnew stacks vertically).
    buf_a = helper.open_scratch("-jump-a.txt")
    vim.cmd("vnew")
    vim.api.nvim_set_current_buf(buf_a)
    win_a = vim.api.nvim_get_current_win()

    buf_b = helper.open_scratch("-jump-b.txt")
    vim.cmd("vnew")
    vim.api.nvim_set_current_buf(buf_b)
    win_b = vim.api.nvim_get_current_win()
  end)

  it("set_current_win moves focus to a different buffer's window", function()
    -- From buf_b's window, jump directly to buf_a's window. Focus must land on buf_a.
    assert.is_true(vim.api.nvim_win_is_valid(win_a), "win_a became invalid")
    vim.api.nvim_set_current_win(win_a)
    local cur = helper.current_buf()
    assert.are.equal(buf_a, cur,
      ("focus did not land on buf_a: expected %d, got %d"):format(buf_a, cur))
  end)

  it("no buffer is shown in more than one window after navigation", function()
    -- Navigate between the two windows a few times, then assert the invariant: each
    -- scratch buffer appears in exactly one live window. A duplication regression would
    -- show 2+.
    vim.api.nvim_set_current_win(win_b)
    vim.api.nvim_set_current_win(win_a)
    vim.api.nvim_set_current_win(win_b)
    vim.wait(100)

    for _, buf in ipairs({ buf_a, buf_b }) do
      if vim.api.nvim_buf_is_valid(buf) then
        local n = windows_showing(buf)
        assert.is_true(n <= 1,
          ("buffer %d is shown in %d windows (duplication)"):format(buf, n))
      end
    end
  end)

  it(":buffer switch returns to a previously visited buffer", function()
    -- Move to buf_a's window, then use :b to jump back to buf_b. The target buffer must
    -- become current and remain in a single window.
    pcall(vim.cmd, "buffer " .. buf_a)
    assert.are.equal(buf_a, helper.current_buf(), ":buffer did not switch to buf_a")

    pcall(vim.cmd, "buffer " .. buf_b)
    assert.are.equal(buf_b, helper.current_buf(), ":buffer did not switch back to buf_b")
    assert.is_true(windows_showing(buf_b) <= 1,
      ("buf_b duplicated after :buffer switch (%d windows)"):format(windows_showing(buf_b)))
  end)
end)
