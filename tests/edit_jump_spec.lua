-- Pins the ClaudeCodeDiffClosed reason mapping in edit-jump.on_diff_closed. The plugin fires
-- this User autocmd with a `reason` string on every diff close; we must jump ONLY on accept
-- (the change is now on disk) and never on reject or a plain view close, or we would point the
-- user at a file that was not actually edited. These reason strings come from claudecode.nvim's
-- diff.lua - if they change there, this spec fails and the mapping must be re-verified.

local edit_jump = require("harness-decorators.edit-jump")

describe("edit-jump.on_diff_closed reason mapping", function()
  local orig_on_edit
  local calls = {}

  setup(function()
    -- Replace on_edit with a recorder so we can assert whether the close was treated as an
    -- accept (jump) without driving the real focus/jump machinery.
    orig_on_edit = edit_jump.on_edit
    calls = {}
    edit_jump.on_edit = function(args)
      table.insert(calls, args)
    end
  end)

  teardown(function()
    edit_jump.on_edit = orig_on_edit
  end)

  it("jumps on the accept reason ('diff tab closed after save')", function()
    edit_jump.on_diff_closed({ data = { reason = "diff tab closed after save", file_path = "/x/y.lua" } })
    assert.are.equal(1, #calls, "accept must trigger a jump")
  end)

  it("does not jump on reject reasons", function()
    calls = {}
    edit_jump.on_diff_closed({ data = { reason = "diff tab closed after reject", file_path = "/x/y.lua" } })
    assert.are.equal(0, #calls, "reject must not trigger a jump")
  end)

  it("does not jump on bulk-close or disconnect reasons", function()
    for _, reason in ipairs({ "close all diffs", "client disconnected", "shutdown", "replaced by new diff" }) do
      calls = {}
      edit_jump.on_diff_closed({ data = { reason = reason, file_path = "/x/y.lua" } })
      assert.are.equal(0, #calls, ("reason %q must not trigger a jump"):format(reason))
    end
  end)

  it("does not jump when there is no reason or no data", function()
    calls = {}
    edit_jump.on_diff_closed({})
    edit_jump.on_diff_closed({ data = {} })
    assert.are.equal(0, #calls, "missing reason/data must not trigger a jump")
  end)
end)
