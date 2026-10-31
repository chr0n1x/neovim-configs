-- Spec for the unified harness terminal table (Option A, Task 6; Task 7 rework).
--
-- park is now backed by term.lua (one Snacks float per harness, no claudecode handle). The table maps
-- harness -> { inst = snacks.terminal|nil }. This spec drives the observable routing: show_selected
-- opens the ACTIVE harness's own float (never another's) - the guarantee that fixes "maki shows claude". Snacks.terminal.open is stubbed
-- to return fake instances backed by windowless buffers, so no real PTY or window is created in
-- headless.
local helper = require("tests.helper")
local state = require("harness-decorators.state")
local keymaps = require("harness-decorators.keymaps")
local active = require("harness-decorators.active")

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
    active.set(original_harness)
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

  it("show_selected opens the active harness's own float and returns it", function()
    local park = require("harness-decorators.park")
    require("harness-decorators.state")._reset()
    active.set(original_harness)

    local shown = park.show_selected()
    assert.are.equal(original_harness, shown, "show_selected must return the active harness")
    assert.is_not_nil(term_mod.bufnr(original_harness), "the active harness's float must be open after show_selected")
  end)

  it("show_selected shows the ACTIVE harness even if another was opened last (no shared handle)", function()
    local park = require("harness-decorators.park")
    require("harness-decorators.state")._reset()
    -- Open maki first, then show the active harness. The shown buffer must be its own, not maki's.
    local maki_buf = term_mod.open("maki").buf
    active.set(original_harness)
    local shown = park.show_selected()

    assert.are.equal(original_harness, shown)
    local shown_buf = term_mod.bufnr(original_harness)
    assert.is_not_nil(shown_buf, "the active harness must have a live float")
    assert.are_not.equal(maki_buf, shown_buf, "showing the active harness must NOT reuse another harness's buffer")
  end)

  it(
    "Given the active harness's record was dropped (exited), When show_selected, Then it reopens the active harness",
    function()
      local park = require("harness-decorators.park")
      require("harness-decorators.switch").init(original_harness)
      require("harness-decorators.state")._reset()
      local shown = park.show_selected()
      assert.are.equal(original_harness, shown, "a dropped record must still reopen the active harness")
      assert.is_not_nil(term_mod.bufnr(original_harness), "the current harness's float must be open")
    end
  )

  it(
    "Given the active harness and another harness whose record says selected, When show_selected, Then the active harness opens",
    function()
      local park = require("harness-decorators.park")
      require("harness-decorators.state")._reset()
      local other = original_harness == "maki" and "copilot" or "maki"
      active.set(original_harness)
      state.entry(other).selected = true
      local shown = park.show_selected()
      assert.are.equal(original_harness, shown)
      assert.is_not_nil(term_mod.bufnr(original_harness), "the active harness's float must be open")
      assert.is_nil(term_mod.bufnr(other), "a stale selected record must not open its harness")
    end
  )
end)
