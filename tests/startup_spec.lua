-- Tier 1: startup wiring. The full real config has already loaded in this nvim (see runner.lua).
--
-- The old A1 regression here asserted that claudecode's terminal_cmd matched the active harness's
-- env module (before the fix, ai-harness.lua referenced an undefined `command` global so the cmd
-- was nil at startup and a fresh NVIM_LLM_HARNESS=maki silently ran claude). That plugin is gone:
-- there is no shared terminal_cmd to desync. The equivalent guarantee now lives in term.lua's Task
-- 7 contract - each harness's float resolves its OWN command from its env module at open time, so
-- a wrong-harness command is impossible by construction. These tests pin that the startup wiring
-- actually ran (keymaps registered for the active harness) and that the env command is well-formed.

local helper = require("tests.helper")

describe("startup: config loads cleanly", function()
  it("has no Lua errors from the full-config load", function()
    local err = helper.lua_errors()
    assert.are.equal("", err, "full-config load produced a Lua error: " .. err)
  end)

  it("startup wiring ran: the active harness is recorded and its keymaps build cleanly", function()
    local harness = helper.active_harness()
    assert.is_not_nil(harness, "no active harness recorded by switcher - setup did not run")

    -- switch.current() being set proves harness-decorators.init.setup ran at startup (it calls
    -- switch.init). We do NOT assert on a live <leader>cl keymap here: that is global state other
    -- specs mutate (switch/clear), so it would be order-dependent. Instead we assert the pure
    -- function the wiring depends on - keymaps.build(harness) returns a well-formed spec list that
    -- includes the harness-agnostic switcher (<leader>cl).
    local specs = require("harness-decorators.keymaps").build(harness)
    assert.is_table(specs, "keymaps.build returned no spec list")
    assert.is_true(#specs > 0, "keymaps.build returned an empty spec list for " .. tostring(harness))

    local has_switcher = false
    for _, spec in ipairs(specs) do
      if spec[1] == "<leader>cl" then
        has_switcher = true
      end
    end
    assert.is_true(has_switcher, "keymaps.build output is missing the <leader>cl switcher spec")
  end)
end)

describe("startup: env command is well-formed for the active harness", function()
  it("the env command is a non-empty string (not nil)", function()
    local harness = helper.active_harness()
    assert.is_not_nil(harness)
    local cmd = helper.env_command(harness)
    assert.is_string(cmd, "env module for " .. tostring(harness) .. " returned non-string")
    assert.is_not.equal("", cmd, "env command is empty")
  end)

  it("term.lua resolves the same command at open time (Task 7 contract)", function()
    local harness = helper.active_harness()
    assert.is_not_nil(harness)
    local expected = helper.env_command(harness)
    local actual = helper.term_spawn_cmd(harness)
    assert.are.equal(expected, actual,
      ("term spawn cmd desync for %s: expected %q (env module), got %q"):format(
        harness, tostring(expected), tostring(actual)))
  end)
end)
