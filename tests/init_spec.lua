-- Idempotency spec for harness-decorators.setup_auto_follow (Task 14). The function is called
-- from the first <leader>c press; before the fix it re-ran its startup resets and re-registered
-- the jump autocmds on EVERY first press, so closing + reopening the terminal in the same nvim
-- session wiped dedup/pin state and re-pinned (duplicate notifications/jumps). This spec pins
-- that a second call is a no-op.

local decorators = require("harness-decorators")
local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")
local watcher = require("harness-decorators.watcher")

describe("setup_auto_follow idempotency (Task 14)", function()
  it("a second call does not re-run the startup resets", function()
    -- Prime a dedup key and a pin, as a live session would.
    utils.mark_key_seen("sentinel-key")
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/sentinel.jsonl"

    -- First call: registers autocmds + runs resets (clearing the sentinel state above).
    decorators.setup_auto_follow()
    assert.is_false(utils.key_seen("sentinel-key"), "first call should have reset dedup")
    assert.is_nil(watcher.pinned_jsonl_path, "first call should have reset the pin")

    -- Re-establish the same state, as a live session would after the first setup.
    utils.mark_key_seen("sentinel-key-2")
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/sentinel.jsonl"

    -- Second call: must be a no-op - the sentinel state survives.
    decorators.setup_auto_follow()
    assert.is_true(utils.key_seen("sentinel-key-2"), "second setup_auto_follow must NOT reset dedup (idempotency)")
    assert.are.equal(
      "/home/u/.claude/projects/x/sentinel.jsonl",
      watcher.pinned_jsonl_path,
      "second setup_auto_follow must NOT reset the pin (idempotency)"
    )

    -- Restore so later specs see a clean slate.
    utils.reset_dedup()
    watcher.pinned_jsonl_path = nil
  end)

  it("does not duplicate the HarnessEdit jump autocmd across calls", function()
    -- Count how many HarnessEdit autocmds are registered by our group after each call. A
    -- re-registration would grow this; idempotency keeps it at one.
    local function count_harness_edit()
      local n = 0
      for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "User", pattern = "HarnessEdit" })) do
        n = n + 1
      end
      return n
    end

    local before = count_harness_edit()
    decorators.setup_auto_follow()
    local after_first = count_harness_edit()
    decorators.setup_auto_follow()
    local after_second = count_harness_edit()

    -- The first call may add the autocmd (if not already present from a prior spec); the
    -- second must add none.
    assert.are.equal(
      after_first,
      after_second,
      ("second setup_auto_follow re-registered the HarnessEdit autocmd (%d -> %d)"):format(after_first, after_second)
    )
    _ = before
  end)
end)

describe("setup activation contracts", function()
  local switch = require("harness-decorators.switch")
  local keymaps = require("harness-decorators.keymaps")
  local state = require("harness-decorators.state")
  local saved

  before_each(function()
    saved = {
      current = switch.current(),
      harness = active.get(),
      records = state.table,
      pi = require("harness-decorators.pi"),
      autocmds = {},
    }
    saved.hook = saved.pi.on_activate
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = { "WinLeave", "ColorScheme" } })) do
      if autocmd.id then
        saved.autocmds[autocmd.id] = true
      end
    end
    state._reset()
  end)

  after_each(function()
    saved.pi.on_activate = saved.hook
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = { "WinLeave", "ColorScheme" } })) do
      if autocmd.id and not saved.autocmds[autocmd.id] then
        vim.api.nvim_del_autocmd(autocmd.id)
      end
    end
    switch.init(saved.current)
    state.table = saved.records
    keymaps.clear()
    keymaps.apply(keymaps.build(saved.harness))
  end)

  it("Given a pi startup hook, When setup pi runs, Then on_activate runs exactly once", function()
    local calls = 0
    saved.pi.on_activate = function()
      calls = calls + 1
    end
    decorators.setup("pi")
    assert.are.equal(1, calls)
    assert.are.equal("pi", switch.current())
    assert.are.equal("pi", vim.fn.maparg("<leader>c", "n", false, true).desc)
  end)

  it("Given an unknown startup harness, When setup runs, Then a clear error names that harness", function()
    local name = "missing-startup-harness"
    local ok, err = pcall(decorators.setup, name)
    assert.is_false(ok, "an unknown startup harness must raise")
    assert.is_truthy(
      tostring(err):find("module 'harness-decorators." .. name .. "' not found", 1, true),
      "the error must identify the missing adapter, not its keymaps"
    )
  end)
end)
