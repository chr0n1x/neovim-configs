-- Spec for the unified harness terminal table (Option A, Task 6; Task 7 rework).
--
-- park is now backed by term.lua (one Snacks float per harness, no claudecode handle). The table maps
-- harness -> { inst = snacks.terminal|nil, selected = boolean }. This spec drives the observable
-- routing: set_selected marks exactly one, park backgrounds only a live harness (via term.hide), and
-- show_selected opens the SELECTED harness's own float (never another's) - the guarantee that fixes
-- "maki shows claude". Snacks.terminal.open is stubbed to return fake instances backed by windowless
-- buffers, so no real PTY or window is created in headless. The re-show-vs-fresh-spawn seam (does a
-- parked float resume vs spawn) is not observable headless and is left as a manual check - see the
-- PRD.
local helper = require("tests.helper")
local state = require("harness-decorators.state")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

---Reset the shared state table (term and park now share it - one reset clears both).
local function park_reset_all()
  require("harness-decorators.state")._reset()
end

describe("park: unified harness terminal table (Task 6/7)", function()
  local term_mod
  local snacks
  local orig_open
  local original_harness
  local orig_env

  ---A fake Snacks instance backed by a windowless buffer.
  local function make_fake(buf)
    return {
      buf = buf,
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
      -- Index self (like real Snacks.win:buf_valid) so a plain-function call would E5108 - term must use
      -- method syntax.
      buf_valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
    }
  end

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness")
    orig_env = os.getenv("NVIM_LLM_HARNESS")
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      return make_fake(vim.api.nvim_create_buf(false, true))
    end
    park_reset_all()
  end)

  teardown(function()
    if snacks then
      snacks.open = orig_open
    end
    park_reset_all()
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    utils.harness = original_harness
  end)

  it("set_selected marks the given harness and clears the others", function()
    local park = require("harness-decorators.park")
    park.set_selected(original_harness)
    park.set_selected("maki")

    local entries = {}
    for _, e in ipairs(park._all_for_test()) do
      entries[e.harness] = e.selected
    end
    assert.is_true(entries["maki"], "maki should be selected")
    assert.is_falsy(entries[original_harness], original_harness .. " should be unselected after maki is chosen")
  end)

  it("park backgrounds a live harness (hides its float) without deleting the buffer", function()
    local park = require("harness-decorators.park")
    -- Give the harness a live instance so park has something to background.
    require("harness-decorators.state")._reset()
    local inst = term_mod.open(original_harness)
    assert.is_not_nil(inst.buf, "open must create an instance with a buffer")

    local parked = park.park(original_harness)
    assert.is_true(parked, "park should report it backgrounded a live terminal")
    assert.is_true(vim.api.nvim_buf_is_valid(inst.buf), "the buffer must survive parking (resume depends on it)")
  end)

  it("park is a no-op when the harness has no live terminal", function()
    local park = require("harness-decorators.park")
    require("harness-decorators.state")._reset()
    local parked = park.park(original_harness)
    assert.is_false(parked, "parking a never-opened harness should be a no-op")
  end)

  it("list drops entries whose buffer has died", function()
    local park = require("harness-decorators.park")
    require("harness-decorators.state")._reset()
    local inst = term_mod.open(original_harness)
    -- list must include it while alive.
    local before = park.list()
    assert.equal(1, #before, "a live harness should appear in list")
    -- Kill the buffer: its process exited.
    vim.api.nvim_buf_delete(inst.buf, { force = true })
    local after = park.list()
    assert.equal(0, #after, "a dead harness's buffer must be dropped from list")
  end)

  it("show_selected opens the selected harness's own float and returns it", function()
    local park = require("harness-decorators.park")
    require("harness-decorators.state")._reset()
    park.set_selected(original_harness)

    local shown = park.show_selected()
    assert.are.equal(original_harness, shown, "show_selected must return the selected harness")
    assert.is_not_nil(term_mod.bufnr(original_harness), "the selected harness's float must be open after show_selected")
  end)

  it("show_selected shows the SELECTED harness even if another was opened last (no shared handle)", function()
    local park = require("harness-decorators.park")
    require("harness-decorators.state")._reset()
    -- Open maki first, then select claude and show. The shown buffer must be claude's own, not maki's.
    local maki_buf = term_mod.open("maki").buf
    park.set_selected(original_harness)
    local shown = park.show_selected()

    assert.are.equal(original_harness, shown)
    local shown_buf = term_mod.bufnr(original_harness)
    assert.is_not_nil(shown_buf, "selected harness must have a live float")
    assert.are_not.equal(maki_buf, shown_buf, "showing the selected harness must NOT reuse another harness's buffer")
  end)

  it("show_selected is a no-op when nothing is selected", function()
    local park = require("harness-decorators.park")
    state._reset()
    require("harness-decorators.state")._reset()
    local shown = park.show_selected()
    assert.is_nil(shown, "no selection means show_selected does nothing")
  end)
end)
