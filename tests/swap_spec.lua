-- Tier 3: harness swap. Verifies <leader>cl's underlying switch() re-points the
-- terminal command and rebinds keymaps, without leaving a stale harness active.
--
-- We call switch().switch(new_harness) directly (the same code path <leader>cl drives
-- via the telescope picker) so the test is deterministic and doesn't depend on driving
-- an interactive picker. After switching, terminal_cmd must equal the NEW harness's env
-- command and the switcher must report the new harness as active.

local helper = require("tests.helper")

describe("swap: switch() re-points terminal_cmd", function()
  local original_harness

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to swap from")
  end)

  teardown(function()
    -- Restore the original harness so other specs see the config's default state.
    if original_harness then
      pcall(require("harness-decorators.switch").switch, original_harness)
    end
  end)

  it("switches to a different harness and its float resolves its own command (Task 7)", function()
    local sw = require("harness-decorators.switch")
    -- Pick a harness that is not the current one (deterministic: first in the list).
    local target = nil
    for _, h in ipairs(require("harness-decorators.utils").list_harnesses()) do
      if h ~= original_harness then
        target = h
        break
      end
    end
    assert.is_not_nil(target, "no alternate harness to switch to")

    sw.switch(target)

    assert.are.equal(target, helper.active_harness(),
      ("switcher did not record new harness: expected %s, got %s"):format(
        target, tostring(helper.active_harness())))

    -- Task 7 contract: there is no global terminal_cmd to re-point. The active harness's float
    -- resolves its OWN env command at open time. After switching, that must be target's command -
    -- never the outgoing harness's (the original A1 bug was maki starting claude).
    local expected = helper.env_command(target)
    local actual = helper.term_spawn_cmd(target)
    assert.are.equal(expected, actual,
      ("after switch to %s, its float must resolve its own command: expected %q, got %q"):format(
        target, tostring(expected), tostring(actual)))
  end)

  it("switching to the same harness is a no-op (no error)", function()
    local sw = require("harness-decorators.switch")
    local cur = helper.active_harness()
    local ok = pcall(sw.switch, cur)
    assert.is_true(ok, "switch() to the current harness errored")
  end)

  it("rejects an unknown harness", function()
    local sw = require("harness-decorators.switch")
    local before = helper.active_harness()
    -- Should notify an error and not change state.
    pcall(sw.switch, "definitely-not-a-harness")
    assert.are.equal(before, helper.active_harness(),
      "switching to an unknown harness changed the active harness")
  end)
end)
