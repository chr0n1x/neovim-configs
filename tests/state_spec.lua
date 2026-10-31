-- Spec for the unified per-harness terminal state.
--
-- The contract under test: there is ONE table holding every annotation about a harness - its live
-- Snacks instance, cwd and open time - so nothing has to be kept in sync across modules. term.lua
-- and park.lua are thin layers over it; this spec pins the invariant that makes that safe:
--   * state.table[harness] is the single record (no parallel registry anywhere)
--   * term.open records the SAME instance on that record (inst == what open returned)
--   * changing the active harness leaves every record's instance in place
-- Snacks.terminal.open is stubbed to return fake instances backed by windowless buffers, so no real
-- PTY or window is created in headless.
local helper = require("tests.helper")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")

describe("state: single per-harness record (Task 8)", function()
  local state
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
      buf_valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
    }
  end

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness")
    orig_env = os.getenv("NVIM_LLM_HARNESS")
    state = require("harness-decorators.state")
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      return make_fake(vim.api.nvim_create_buf(false, true))
    end
    state._reset()
  end)

  teardown(function()
    if snacks then
      snacks.open = orig_open
    end
    state._reset()
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    active.set(original_harness)
  end)

  it("Given a never-opened harness, When its record is created, Then it is in the table with no instance", function()
    local entry = state.entry(original_harness)
    assert.are.equal(entry, state.table[original_harness], "entry must create the harness's record")
    assert.is_nil(entry.inst, "a never-opened harness has no instance yet")
  end)

  it("term.open records the SAME instance on the shared record (no duplicated handle)", function()
    -- The core invariant: the instance term returns and the one stored on state.table must be the
    -- identical table. If any layer kept its own copy, a later show/hide could act on a stale handle.
    local inst = term_mod.open(original_harness)
    assert.is_not_nil(inst, "open must return an instance")

    local entry = state.table[original_harness]
    assert.is_not_nil(entry, "open must record the harness in the shared table")
    assert.are.equal(inst, entry.inst, "state.table[harness].inst must be the SAME table open returned")
  end)

  it(
    "Given an open harness, When another harness becomes active, Then the open instance stays on its record",
    function()
      local a = term_mod.open(original_harness)
      local other = nil
      for _, h in ipairs(utils.list_harnesses()) do
        if h ~= original_harness then
          other = h
          break
        end
      end
      assert.is_not_nil(other, "no alternate harness to activate")

      active.set(other)

      assert.are.equal(
        a,
        state.table[original_harness].inst,
        "activating another harness must not drop the open instance"
      )
    end
  )

  it("state._reset clears every record", function()
    term_mod.open(original_harness)
    state._reset()
    assert.are.equal(0, vim.tbl_count(state.table), "_reset must leave an empty table")
  end)

  it("harness_of returns the harness whose record holds the instance, nil for an unknown one", function()
    state._reset()
    local a = term_mod.open("claude")
    local b = term_mod.open("maki")
    assert.are.equal("claude", state.harness_of(a))
    assert.are.equal("maki", state.harness_of(b))
    assert.is_nil(state.harness_of({}))
    assert.is_nil(state.harness_of(nil))
  end)
end)
