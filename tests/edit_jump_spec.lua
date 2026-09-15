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

  it("reuses an existing target window instead of duplicating its buffer", function()
    local path = vim.fn.tempname() .. "-edit-jump.txt"
    local file = assert(io.open(path, "w"))
    file:write("first\nsecond\nthird\n")
    file:close()

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local target_win = vim.api.nvim_get_current_win()
    vim.cmd("new")
    local other_win = vim.api.nvim_get_current_win()
    local old_jump_win = edit_jump.jump_win
    edit_jump.jump_win = other_win

    edit_jump.on_edit({
      data = {
        file_path = path,
        starting_line = 2,
        jsonl_path = nil,
      },
    })
    vim.wait(800)

    local target_buf = vim.api.nvim_win_get_buf(target_win)
    assert.are.equal(path, vim.api.nvim_buf_get_name(target_buf))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(target_win)[1])
    assert.are_not.equal(target_buf, vim.api.nvim_win_get_buf(other_win))

    edit_jump.jump_win = old_jump_win
    pcall(vim.api.nvim_win_close, other_win, true)
    pcall(vim.api.nvim_buf_delete, target_buf, { force = true })
    vim.fn.delete(path)
  end)

  it("on_diff_closed no longer exists (diff path removed)", function()
    assert.is_nil(edit_jump.on_diff_closed, "on_diff_closed should have been removed with the diff path")
  end)
end)
