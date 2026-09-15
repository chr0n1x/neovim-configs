-- Pins edit-jump's jump-autocmd wiring. The old spec here pinned the
-- ClaudeCodeDiffClosed reason mapping (jump only on an accepted diff), but that path came from
-- claudecode.nvim's diff view, which is no longer a dependency - so on_diff_closed and its
-- autocmd are gone. What remains: create_jump_autocmds must register the HarnessEdit User autocmd
-- (fired by our own JSONL watcher) and must NOT reference any removed plugin event.

local edit_jump = require("harness-decorators.edit-jump")

describe("edit-jump.create_jump_autocmds wiring", function()
  it("registers a HarnessEdit autocmd and no ClaudeCodeDiffClosed one", function()
    local group = vim.api.nvim_create_augroup("TestJumpGroup", { clear = true })
    edit_jump.create_jump_autocmds(group)

    local events = {}
    for _, ev in ipairs(vim.api.nvim_get_autocmds({ group = "TestJumpGroup" })) do
      table.insert(events, ev.event .. (ev.pattern and (":" .. ev.pattern) or ""))
    end
    -- HarnessEdit must be present.
    local has_harness_edit = false
    for _, e in ipairs(events) do
      if e == "User:HarnessEdit" then
        has_harness_edit = true
      end
    end
    assert.is_true(has_harness_edit, "HarnessEdit autocmd not registered; got: " .. table.concat(events, ", "))

    -- The removed plugin diff event must NOT be registered.
    for _, e in ipairs(events) do
      assert.is_not.match("ClaudeCodeDiffClosed", e, "removed diff autocmd is still registered")
    end
  end)

  it("on_diff_closed no longer exists (diff path removed)", function()
    assert.is_nil(edit_jump.on_diff_closed, "on_diff_closed should have been removed with the diff path")
  end)
end)
