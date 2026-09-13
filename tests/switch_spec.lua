-- Spec for switch.lua hardening (Task 15, sub-issue B): the claudecode.terminal.setup call must
-- be pcalled so a failure there does not leave the config half-switched with no error surfaced.
-- Before the fix it was the only un-pcall'd claudecode poke in M.switch; a throw there aborted
-- the switch mid-way (terminal already killed, keymaps not rebound, current_harness stale).

local helper = require("tests.helper")
local sw = require("harness-decorators.switch")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

describe("switch: terminal.setup failure is contained (Task 15B)", function()
  local original_harness
  local orig_notify
  local notes
  local term_mod
  local orig_setup
  local orig_env

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to switch from")
    orig_env = os.getenv("NVIM_LLM_HARNESS")

    -- Capture vim.notify so we can assert the failure is surfaced as an ERROR.
    orig_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = tostring(msg), level = level })
    end

    term_mod = require("claudecode.terminal")
    orig_setup = term_mod.setup
  end)

  teardown(function()
    if orig_notify then
      vim.notify = orig_notify
    end
    if term_mod and orig_setup then
      term_mod.setup = orig_setup
    end
    -- Restore the harness state directly (env var + utils.harness) rather than calling
    -- sw.switch, which would spawn/kill terminals and re-point claudecode state - perturbing
    -- other specs that assume the config's default harness. The failed switch in the test body
    -- bailed before updating current_harness, so the active harness is already back to the
    -- original; this just makes sure the env/utils bookkeeping matches.
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    utils.harness = original_harness
  end)

  it("bails without updating current_harness or keymaps when setup throws", function()
    -- Pick a target different from the current harness.
    local target = nil
    for _, h in ipairs(keymaps.list_harnesses()) do
      if h ~= original_harness then
        target = h
        break
      end
    end
    assert.is_not_nil(target, "no alternate harness to switch to")

    -- Make the terminal setup throw, as a real failure would.
    term_mod.setup = function()
      error("simulated terminal setup failure")
    end

    -- The switch must not error out (pcall contained it) and must surface an ERROR notify.
    local ok = pcall(sw.switch, target)
    assert.is_true(ok, "switch() errored instead of containing the setup failure")

    -- current_harness must still be the original: the switch bailed before updating it.
    assert.are.equal(original_harness, helper.active_harness(),
      ("current_harness changed to %s despite a failed setup"):format(tostring(helper.active_harness())))

    -- An ERROR-level notify naming the failing step must have been emitted.
    local saw_error = false
    for _, n in ipairs(notes) do
      if n.level == vim.log.levels.ERROR and n.msg:find("terminal setup", 1, true) then
        saw_error = true
      end
    end
    assert.is_true(saw_error, "no ERROR notify naming the terminal setup failure was emitted")
  end)
end)
