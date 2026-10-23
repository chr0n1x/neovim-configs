-- Spec for util/live-previewer: renders caller-built lines into the preview buffer, refreshes on a
-- timer, highlights pattern matches in the preview window, and stops the timer on teardown.
-- telescope.previewers is stubbed so the define_preview/teardown callbacks can be driven directly.
describe("live-previewer", function()
  local live
  local captured
  local orig_previewers
  local buf, win

  before_each(function()
    orig_previewers = package.loaded["telescope.previewers"]
    package.loaded["telescope.previewers"] = {
      new_buffer_previewer = function(opts)
        captured = opts
        return opts
      end,
    }
    package.loaded["util.live-previewer"] = nil
    live = require("util.live-previewer")
    buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    if captured and captured.teardown then
      captured.teardown()
    end
    package.loaded["telescope.previewers"] = orig_previewers
    package.loaded["util.live-previewer"] = nil
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  local function self_state()
    return { state = { bufnr = buf, winid = win } }
  end

  it("renders the lines for the entry into the buffer and moves the cursor to the bottom", function()
    local seen
    live.new({
      lines = function(entry, winid)
        seen = { entry = entry, winid = winid }
        return { "one", "two", "three" }
      end,
    })
    captured.define_preview(self_state(), { value = "x" })
    assert.are.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal("x", seen.entry.value)
    assert.are.equal(win, seen.winid)
    assert.is_false(vim.bo[buf].modifiable)
    assert.are.equal(3, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("highlights pattern matches on the preview window", function()
    live.new({
      lines = function()
        return { "an error here" }
      end,
      patterns = { { "ErrorMsg", [[\cerror]] } },
    })
    captured.define_preview(self_state(), { value = "x" })
    local matches = vim.fn.getmatches(win)
    assert.are.equal(1, #matches)
    assert.are.equal("ErrorMsg", matches[1].group)
  end)

  it("does not stack matches across re-renders", function()
    live.new({
      lines = function()
        return { "error" }
      end,
      patterns = { { "ErrorMsg", [[\cerror]] } },
    })
    local s = self_state()
    captured.define_preview(s, { value = "x" })
    captured.define_preview(s, { value = "x" })
    assert.are.equal(1, #vim.fn.getmatches(win))
  end)

  it("re-renders on the timer and stops after teardown", function()
    local n = 0
    live.new({
      lines = function()
        n = n + 1
        return { "render " .. n }
      end,
    })
    captured.define_preview(self_state(), { value = "x" })
    assert.are.equal(1, n)
    vim.wait(1300, function()
      return n >= 3
    end, 50)
    assert.is_true(n >= 3)
    captured.teardown()
    local after = n
    vim.wait(1200, function()
      return false
    end, 50)
    assert.are.equal(after, n)
  end)
end)
