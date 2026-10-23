-- Spec for the zen-mode + tmux navigation integration:
--   1. tmux.lua: <C-h>/<C-j>/<C-k>/<C-l> in the zen window bypass wincmd and call
--      tmux select-pane directly.
--   2. zen-mode.lua: FocusGained reopens zen mode after a tmux pane round-trip.
--
-- The full real config is already loaded (see runner.lua), so the keymaps and
-- autocmds are live.

describe("tmux nav: zen window bypasses wincmd", function()
  local zen_view

  setup(function()
    zen_view = require("zen-mode.view")
  end)

  teardown(function()
    zen_view.win = nil
    zen_view.parent = nil
  end)

  ---Create a minimal float that mimics the zen window.
  local function make_zen_float()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = 20,
      height = 10,
      row = 1,
      col = 1,
    })
    return buf, win
  end

  ---Find the <C-h> normal-mode keymap handler (nvim stores it as "<C-H>").
  local function c_h_handler()
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if (m.lhs == "<C-h>" or m.lhs == "<C-H>") and m.callback then
        return m.callback
      end
    end
    return nil
  end

  it(
    "Given zen mode is open and focus is in the zen window, When the <C-h handler runs, Then tmux select-pane -L is called and focus stays in the zen window",
    function()
      local buf, win = make_zen_float()
      zen_view.win = win
      zen_view.parent = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(win)

      local handler = c_h_handler()
      assert.is_not_nil(handler, "<C-h> keymap with callback not found")

      local system_calls = {}
      local real_system = vim.fn.system
      vim.fn.system = function(cmd)
        table.insert(system_calls, cmd)
        return ""
      end
      vim.env.TMUX = "/tmp/fake-tmux-socket,1234"

      handler()

      vim.fn.system = real_system
      vim.env.TMUX = nil

      assert.are.same(1, #system_calls, "expected exactly one tmux call, got " .. #system_calls)
      local cmd = system_calls[1]
      assert.truthy(cmd:find("select-pane", 1, true), "should contain 'select-pane': " .. cmd)
      assert.truthy(cmd:find("-L", 1, true), "should contain '-L': " .. cmd)
      assert.are.equal(win, vim.api.nvim_get_current_win(), "focus should remain in the zen window")

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  )

  it(
    "Given zen mode is closed, When the <C-h handler runs, Then no direct tmux call is made (normal plugin path)",
    function()
      zen_view.win = nil

      local handler = c_h_handler()
      assert.is_not_nil(handler, "<C-h> keymap with callback not found")

      local system_calls = {}
      local real_system = vim.fn.system
      vim.fn.system = function(cmd)
        table.insert(system_calls, cmd)
        return ""
      end
      vim.env.TMUX = "/tmp/fake-tmux-socket,1234"

      handler()

      vim.fn.system = real_system
      vim.env.TMUX = nil

      -- When zen is closed, the handler should fall through to the normal
      -- plugin path (wincmd h), which does NOT call vim.fn.system directly.
      local direct_calls = 0
      for _, cmd in ipairs(system_calls) do
        if cmd:match("select-pane") then
          direct_calls = direct_calls + 1
        end
      end
      assert.are.equal(0, direct_calls, "zen_aware should not call tmux when zen is closed")
    end
  )
end)

describe("zen-mode: FocusGained reopens zen after tmux pane switch", function()
  local zen_view

  setup(function()
    zen_view = require("zen-mode.view")
  end)

  teardown(function()
    zen_view.win = nil
    zen_view.parent = nil
    pcall(vim.cmd, "autocmd! ZenTmuxNav")
  end)

  it(
    "Given zen is closed but its parent window is still valid, When FocusGained fires, Then zen mode is reopened",
    function()
      local parent_win = vim.api.nvim_get_current_win()
      zen_view.win = nil
      zen_view.parent = parent_win

      local open_called = false
      local real_open = require("zen-mode").open
      require("zen-mode").open = function()
        open_called = true
      end

      vim.api.nvim_exec_autocmds("FocusGained", {})

      vim.wait(200, function()
        return open_called
      end)

      require("zen-mode").open = real_open

      assert.is_true(open_called, "zen-mode.open should have been called on FocusGained")
    end
  )

  it(
    "Given zen is open, When FocusGained fires, Then zen mode is NOT reopened",
    function()
      local buf = vim.api.nvim_create_buf(false, true)
      local zen_win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = 10,
        height = 5,
        row = 1,
        col = 1,
      })
      zen_view.win = zen_win
      zen_view.parent = vim.api.nvim_get_current_win()

      local open_called = false
      local real_open = require("zen-mode").open
      require("zen-mode").open = function()
        open_called = true
      end

      vim.api.nvim_exec_autocmds("FocusGained", {})

      vim.wait(200, function()
        return open_called
      end)

      require("zen-mode").open = real_open

      assert.is_false(open_called, "zen-mode.open should NOT be called when zen is already open")

      vim.api.nvim_win_close(zen_win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  )

  it(
    "Given zen is closed and its parent window is invalid, When FocusGained fires, Then zen mode is NOT reopened",
    function()
      zen_view.win = nil
      zen_view.parent = 99999

      local open_called = false
      local real_open = require("zen-mode").open
      require("zen-mode").open = function()
        open_called = true
      end

      vim.api.nvim_exec_autocmds("FocusGained", {})

      vim.wait(200, function()
        return open_called
      end)

      require("zen-mode").open = real_open

      assert.is_false(open_called, "zen-mode.open should NOT be called when parent is invalid")
    end
  )
end)
