-- Spec for the single owner of the active harness: after switch.activate, every reader of the active
-- harness (sidecar paths, session ids, active.get()) follows the new harness, even when a later
-- activation step such as the watcher restart fails.
local sw = require("harness-decorators.switch")
local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")
local keymaps = require("harness-decorators.keymaps")
local watcher = require("harness-decorators.watcher")
local state = require("harness-decorators.state")
local sidecar = require("harness-decorators.sidecar")

describe("active harness: one owner for every reader", function()
  local saved

  before_each(function()
    saved = {
      current = sw.current(),
      harness = active.get(),
      env = vim.env.NVIM_LLM_HARNESS,
      records = state.table,
      stop = watcher.stop,
      start = watcher.start,
    }
    state._reset()
    watcher.set_harness("claude")
    sw.init("claude")
    vim.env.NVIM_LLM_HARNESS = "claude"
    keymaps.clear()
    keymaps.apply(keymaps.build("claude"))
    watcher.stop = function()
      error("watcher stop failed")
    end
    watcher.start = function() end
  end)

  after_each(function()
    watcher.stop, watcher.start = saved.stop, saved.start
    watcher.set_harness(saved.harness)
    sw.init(saved.current)
    state.table = saved.records
    vim.env.NVIM_LLM_HARNESS = saved.env
    keymaps.clear()
    keymaps.apply(keymaps.build(saved.harness))
  end)

  it(
    "Given claude active and a throwing watcher.stop, When copilot is activated, Then sidecar paths, session ids and active.get() follow copilot",
    function()
      sw.activate("copilot")
      assert.are.equal("copilot", sw.current())
      assert.are.equal("copilot", active.get())
      assert.truthy(sidecar.path("abc"):find("copilot-events-session-abc", 1, true))
      assert.are.equal("sess1", utils.extract_session_id("/tmp/session-state/sess1/events.jsonl"))
    end
  )
end)
