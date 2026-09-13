-- Idempotency spec for harness-decorators.setup_auto_follow (Task 14). The function is called
-- from the first <leader>c press; before the fix it re-ran its startup resets and re-registered
-- the jump autocmds on EVERY first press, so closing + reopening the terminal in the same nvim
-- session wiped dedup/pin state and re-pinned (duplicate notifications/jumps). This spec pins
-- that a second call is a no-op.

local decorators = require("harness-decorators")
local utils = require("harness-decorators.utils")
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
    assert.is_true(utils.key_seen("sentinel-key-2"),
      "second setup_auto_follow must NOT reset dedup (idempotency)")
    assert.are.equal("/home/u/.claude/projects/x/sentinel.jsonl", watcher.pinned_jsonl_path,
      "second setup_auto_follow must NOT reset the pin (idempotency)")

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
    assert.are.equal(after_first, after_second,
      ("second setup_auto_follow re-registered the HarnessEdit autocmd (%d -> %d)"):format(
        after_first, after_second))
    _ = before
  end)
end)
