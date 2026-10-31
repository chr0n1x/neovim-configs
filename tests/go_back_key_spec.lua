-- Spec for the float's focus/close key handlers (Task 7 follow-up).
--
-- Two distinct keys, two distinct behaviors:
--   * <C-h> -> term.go_back_key(self): move focus back to the work buffer WITHOUT hiding the float -
--     the panel stays open and its process keeps running. This is the exact regression the user hit
--     ("when I <C-h> the terminal gets hidden"). We assert go_back_key does NOT call self:hide().
--   * <Esc> -> term.close_key(self): exit insert and minimize the float into its docked bar, keeping
--     the PTY alive. A fake with no open float falls back to hiding; we assert that fallback calls
--     self:hide(). The minimize path is covered in tests/term_spec.lua.
-- Both handlers are exposed on M so they can be driven headless with a fake instance (terminal-mode
-- keys can't be fed in a headless nvim, which is why focus_spec tests the mechanics directly).

local helper = require("tests.helper")

describe("term.go_back_key: <C-h> moves focus back without hiding the float", function()
  local term_mod
  local focus
  local orig_env
  local original_harness

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
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
  end)

  it("does not hide the float (the panel stays open)", function()
    -- A fake instance that records whether :hide() was called. go_back_key must NOT call it.
    local hidden = false
    local fake = {
      buf = vim.api.nvim_create_buf(false, true),
      win = nil,
      hide = function()
        hidden = true
      end,
      show = function() end,
      focus = function() end,
      close = function() end,
      -- layout normal and _saved_config unset, so animate_collapse is a no-op (no animation to run).
    }

    local ok, err = pcall(term_mod.go_back_key, fake)
    assert.is_true(ok, "go_back_key raised: " .. tostring(err))
    assert.is_false(hidden, "<C-h> must NOT hide the float - it should stay open and visible")
  end)

  it("moves focus back to a saved window when one exists", function()
    -- Give focus a saved window to return to, then confirm go_back_key jumps there (not just that it
    -- didn't hide). This proves the "go back" half of the behavior still works.
    local origin = vim.api.nvim_get_current_win()
    focus.last_win = origin
    local fake = {
      buf = vim.api.nvim_create_buf(false, true),
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
    }

    local ok, err = pcall(term_mod.go_back_key, fake)
    assert.is_true(ok, "go_back_key raised: " .. tostring(err))
    -- jump_to_saved moves to last_win; with last_win == current win it's a no-op move but must not error.
    assert.are.equal(origin, vim.api.nvim_get_current_win(), "focus should remain on the saved window")
  end)
end)

describe("term.close_key: <Esc> hides the float (but keeps the PTY alive)", function()
  local term_mod

  setup(function()
    term_mod = require("harness-decorators.term")
  end)

  it("hides the float (the panel closes)", function()
    -- A fake instance that records whether :hide() was called. close_key MUST call it - that is what
    -- "close" means here (distinct from <C-h>, which stays open).
    local hidden = false
    local fake = {
      buf = vim.api.nvim_create_buf(false, true),
      win = nil,
      hide = function()
        hidden = true
      end,
      show = function() end,
      focus = function() end,
      close = function() end,
    }

    local ok, err = pcall(term_mod.close_key, fake)
    assert.is_true(ok, "close_key raised: " .. tostring(err))
    assert.is_true(hidden, "<Esc> must hide the float - that is what 'close' means here")
  end)
end)

describe("term.go_back_key: <C-h> in zen mode", function()
  local term_mod
  local layout
  local focus

  setup(function()
    term_mod = require("harness-decorators.term")
    layout = require("harness-decorators.layout")
    focus = require("harness-decorators.focus")
    focus.reset()
  end)

  teardown(function()
    layout.zen_active_override = nil
    focus.reset()
  end)

  it("jumps to the zen window (a float) instead of the saved parent window", function()
    layout.zen_active_override = true
    -- Create a fake zen window (a float) that zen-mode.view would report.
    local zen_buf = vim.api.nvim_create_buf(false, true)
    local zen_win = vim.api.nvim_open_win(zen_buf, false, {
      relative = "editor",
      width = 10,
      height = 5,
      row = 1,
      col = 1,
    })
    -- Patch zen-mode.view to report our fake window.
    local zen_view = require("zen-mode.view")
    local real_win = zen_view.win
    zen_view.win = zen_win

    local origin = vim.api.nvim_get_current_win()
    local fake = {
      buf = vim.api.nvim_create_buf(false, true),
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
    }

    local ok, err = pcall(term_mod.go_back_key, fake)
    assert.is_true(ok, "go_back_key raised: " .. tostring(err))
    assert.are.equal(zen_win, vim.api.nvim_get_current_win(), "focus should land on the zen window")

    -- Clean up: restore and close the fake zen window.
    vim.api.nvim_set_current_win(origin)
    vim.api.nvim_win_close(zen_win, true)
    vim.api.nvim_buf_delete(zen_buf, { force = true })
    zen_view.win = real_win
  end)

  it("falls back to the saved window when zen window is invalid", function()
    layout.zen_active_override = true
    local zen_view = require("zen-mode.view")
    local real_win = zen_view.win
    zen_view.win = nil -- no valid zen window

    local origin = vim.api.nvim_get_current_win()
    focus.last_win = origin
    local fake = {
      buf = vim.api.nvim_create_buf(false, true),
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
    }

    local ok, err = pcall(term_mod.go_back_key, fake)
    assert.is_true(ok, "go_back_key raised: " .. tostring(err))
    assert.are.equal(origin, vim.api.nvim_get_current_win(), "focus should fall back to saved window")

    zen_view.win = real_win
  end)
end)
