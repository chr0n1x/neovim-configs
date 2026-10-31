-- Harness swap: <leader>cl's underlying switch() makes the new harness active, without leaving a
-- stale harness active.
--
-- We call require("harness-decorators.switch").switch(new_harness) directly (the same code path
-- <leader>cl drives via the picker) so the test is deterministic and doesn't depend on driving an
-- interactive picker. After switching, the switcher must report the NEW harness as active, and
-- that harness's float must resolve its own env command.

local helper = require("tests.helper")

describe("swap: switch() makes the new harness active with its own command", function()
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

  it("switches to a different harness and its float resolves its own command", function()
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

    assert.are.equal(
      target,
      helper.active_harness(),
      ("switcher did not record new harness: expected %s, got %s"):format(target, tostring(helper.active_harness()))
    )

    -- Each harness's float resolves its OWN env command at open time (there is no shared terminal
    -- command). After switching, that must be target's command, never the outgoing harness's (for
    -- example maki starting claude).
    local expected = helper.env_command(target)
    local actual = helper.term_spawn_cmd(target)
    assert.are.equal(
      expected,
      actual,
      ("after switch to %s, its float must resolve its own command: expected %q, got %q"):format(
        target,
        tostring(expected),
        tostring(actual)
      )
    )
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
    assert.are.equal(before, helper.active_harness(), "switching to an unknown harness changed the active harness")
  end)
end)
