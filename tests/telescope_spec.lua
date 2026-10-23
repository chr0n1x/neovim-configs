-- Spec for plugins/telescope.lua: where a picked file opens.

describe("telescope: picked files open in the zen window while zen is open", function()
  local zen_view = require("zen-mode.view")
  local zen_win

  local function selection_window()
    local pick = require("telescope.config").values.get_selection_window
    return pick({}, {})
  end

  after_each(function()
    zen_view.win = nil
    pcall(vim.api.nvim_win_close, zen_win, true)
  end)

  it("Given zen is open, When a file is picked, Then it opens in the zen window", function()
    zen_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 5,
    })
    zen_view.win = zen_win
    assert.are.equal(zen_win, selection_window())
  end)

  it("Given zen is closed, When a file is picked, Then it opens in the window the picker came from", function()
    assert.are.equal(0, selection_window())
  end)
end)
