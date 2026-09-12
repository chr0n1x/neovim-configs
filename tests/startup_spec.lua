-- Tier 1: startup + command selection. This is the A1 regression test.
--
-- The full real config has already loaded in this nvim (see runner.lua). For the
-- active harness, claudecode.state.config.terminal_cmd MUST equal that harness's env
-- module return value. Before the A1 fix, ai-harness.lua referenced an undefined
-- `command` global so terminal_cmd was nil at startup and claudecode silently fell
-- back to "claude" - meaning NVIM_LLM_HARNESS=maki started CLAUDE. That exact bug is
-- what this assertion catches.

local helper = require("tests.helper")

describe("startup: config loads cleanly", function()
  it("has no Lua errors from the full-config load", function()
    local err = helper.lua_errors()
    assert.are.equal("", err, "full-config load produced a Lua error: " .. err)
  end)

  it("loaded claudecode.nvim", function()
    local ok = pcall(require, "claudecode")
    assert.is_true(ok, "claudecode.nvim did not load")
  end)
end)

describe("startup: terminal_cmd matches the active harness (A1)", function()
  it("terminal_cmd equals the active harness's env command", function()
    local harness = helper.active_harness()
    assert.is_not_nil(harness, "no active harness recorded by switcher")

    local expected = helper.env_command(harness)
    local actual = helper.terminal_cmd()

    assert.are.equal(expected, actual,
      ("terminal_cmd desync for %s: expected %q (env module), got %q"):format(
        harness, tostring(expected), tostring(actual)))
  end)

  it("the env command is a non-empty string (not nil)", function()
    local harness = helper.active_harness()
    assert.is_not_nil(harness)
    local cmd = helper.env_command(harness)
    assert.is_string(cmd, "env module for " .. tostring(harness) .. " returned non-string")
    assert.is_not.equal("", cmd, "env command is empty")
  end)
end)
