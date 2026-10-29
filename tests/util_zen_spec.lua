local zen = require("util.zen")

describe("util.zen.win", function()
  local view, real_is_open, real_win, real_parent, float

  before_each(function()
    view = require("zen-mode.view")
    real_is_open, real_win, real_parent = view.is_open, view.win, view.parent
    float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 3,
    })
  end)

  after_each(function()
    view.is_open, view.win, view.parent = real_is_open, real_win, real_parent
    pcall(vim.api.nvim_win_close, float, true)
  end)

  it("Given zen is open with a valid window, Then it returns the window and its parent", function()
    view.is_open = function()
      return true
    end
    view.win, view.parent = float, 1000
    local win, parent = zen.win()
    assert.are.equal(float, win)
    assert.are.equal(1000, parent)
  end)

  it("Given zen is closed, Then it returns nil", function()
    view.is_open = function()
      return false
    end
    view.win = float
    assert.is_nil(zen.win())
  end)

  it("Given zen is open but its window is gone, Then it returns nil", function()
    view.is_open = function()
      return true
    end
    vim.api.nvim_win_close(float, true)
    view.win = float
    assert.is_nil(zen.win())
  end)
end)
