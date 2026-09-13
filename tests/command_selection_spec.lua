-- Per-harness command selection (Task 7). The strongest form of the A1 assertion: for EVERY
-- harness, when it is active its float must resolve to that harness's OWN env command - never
-- another harness's (the original A1 bug was NVIM_LLM_HARNESS=maki starting claude).
--
-- Under Task 7 there is no global terminal_cmd to re-point: term.lua resolves each harness's
-- command from its env module at open time. We switch to each harness in turn (switch().switch is
-- the same code path <leader>cl drives) and assert the active harness's float would spawn ITS OWN
-- command - catching a regression where, say, maki's env returns "maki" but the open path still
-- resolves claude's command.

local helper = require("tests.helper")
local keymaps = require("harness-decorators.keymaps")

describe("command selection: every harness runs its own CLI", function()
  local original_harness

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to start from")
  end)

  teardown(function()
    if original_harness then
      pcall(require("harness-decorators.switch").switch, original_harness)
    end
  end)

  -- One test per discovered harness so a failure names the offending harness. The list is
  -- captured at file-load time (keymaps.list_harnesses just scans the directory), which is
  -- safe - it does not depend on nvim runtime state.
  for _, harness in ipairs(keymaps.list_harnesses()) do
    it(("resolves %s to its own env command"):format(harness), function()
      local sw = require("harness-decorators.switch")
      sw.switch(harness)

      assert.are.equal(harness, helper.active_harness(),
        ("switcher did not record %s as active (got %s)"):format(
          harness, tostring(helper.active_harness())))

      local expected = helper.env_command(harness)
      local actual = helper.term_spawn_cmd(harness)
      assert.is_string(expected,
        ("%s env module returned non-string: %s"):format(harness, tostring(expected)))
      assert.are.equal(expected, actual,
        ("%s desync: its float must resolve %q, got %q (wrong CLI would run)"):format(
          harness, tostring(expected), tostring(actual)))

      -- Guard against the specific A1 failure mode: a non-claude harness must never end up
      -- running "claude".
      if harness ~= "claude" then
        assert.is_not.truthy(tostring(actual):match("^claude%s") or tostring(actual) == "claude",
          ("%s resolved to claude's command: %q"):format(harness, tostring(actual)))
      end
    end)
  end
end)
