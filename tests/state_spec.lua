-- Spec for the unified per-harness terminal state (Task 8).
--
-- The contract under test: there is ONE table holding every annotation about a harness - its live
-- Snacks instance AND its selection bit - so nothing has to be kept in sync across modules. term.lua
-- and park.lua are thin layers over it; this spec pins the invariant that makes that safe:
--   * state.table[harness] is the single record (no parallel registry anywhere)
--   * term.open records the SAME instance on that record (inst == what open returned)
--   * park.set_selected / selected_harness read and write the selection bit on that same record
-- Snacks.terminal.open is stubbed to return fake instances backed by windowless buffers, so no real
-- PTY or window is created in headless.
local helper = require("tests.helper")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

describe("state: single per-harness record (Task 8)", function()
  local state
  local term_mod
  local park
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
    park = require("harness-decorators.park")
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
    utils.harness = original_harness
  end)

  it("holds one record per harness with inst and selected fields", function()
    -- A never-opened, just-selected harness must still have a record: selection does not require a
    -- live instance (the first <leader>c spawns it).
    park.set_selected(original_harness)

    local entry = state.table[original_harness]
    assert.is_not_nil(entry, "set_selected must create the harness's record")
    assert.is_boolean(entry.selected, "selection bit must be a boolean on the record")
    assert.is_true(entry.selected, "the record must carry selected=true")
    assert.is_nil(entry.inst, "a never-opened harness has no instance yet")
  end)

  it("term.open records the SAME instance on the shared record (no duplicated handle)", function()
    -- The core Task 8 invariant: the instance term returns and the one stored on state.table must be
    -- the identical table. If any layer kept its own copy, a later show/hide could act on a stale
    -- handle - the exact drift the old park.registry[harness].inst write-back guarded against.
    local inst = term_mod.open(original_harness)
    assert.is_not_nil(inst, "open must return an instance")

    local entry = state.table[original_harness]
    assert.is_not_nil(entry, "open must record the harness in the shared table")
    assert.are.equal(inst, entry.inst, "state.table[harness].inst must be the SAME table open returned")
  end)

  it("park.set_selected and selected_harness read/write the selection bit on the shared record", function()
    -- Selection must live on the same record as the instance: select one harness while another is
    -- open, and both the selection query and the per-entry bits must agree with state.table.
    local a = term_mod.open(original_harness)
    local other = nil
    for _, h in ipairs(utils.list_harnesses()) do
      if h ~= original_harness then
        other = h
        break
      end
    end
    assert.is_not_nil(other, "no alternate harness to select")

    park.set_selected(other)

    assert.are.equal(other, park.selected_harness(), "selected_harness must report the newly selected one")
    assert.is_true(state.table[other].selected, "the selected record must carry selected=true")
    assert.is_false(state.table[original_harness].selected, "the other record must be unselected")
    -- The open instance is untouched by selection: still live on its own record.
    assert.are.equal(a, state.table[original_harness].inst, "selecting another harness must not drop the open instance")
  end)

  it("park.park keeps the instance on the record and only clears selection (resume depends on it)", function()
    -- Backgrounding hides the float but must NOT delete the instance from the shared record - that is
    -- what makes re-select resume the SAME live process. The buffer must survive too.
    local inst = term_mod.open(original_harness)
    park.set_selected(original_harness)

    local parked = park.park(original_harness)
    assert.is_true(parked, "park should report it backgrounded a live terminal")

    local entry = state.table[original_harness]
    assert.are.equal(inst, entry.inst, "parking must keep the instance on the record (resume)")
    assert.is_false(entry.selected, "parking must clear the selection bit")
    assert.is_true(vim.api.nvim_buf_is_valid(inst.buf), "the buffer must survive parking")
  end)

  it("state._reset clears every record", function()
    term_mod.open(original_harness)
    park.set_selected(original_harness)
    state._reset()
    assert.are.equal(0, vim.tbl_count(state.table), "_reset must leave an empty table")
  end)
end)
