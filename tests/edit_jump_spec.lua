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

  it("Given an edit jump, When it completes, Then it does not block Neovim with vim.wait", function()
    local path = vim.fn.tempname() .. "-edit-jump-noblock.txt"
    local file = assert(io.open(path, "w"))
    file:write("first\nsecond\nthird\n")
    file:close()

    local win = vim.api.nvim_get_current_win()
    local old_jump_win = edit_jump.jump_win
    local old_defer_fn = vim.defer_fn
    local old_wait = vim.wait
    local wait_calls = 0
    edit_jump.jump_win = win
    vim.defer_fn = function(callback, delay)
      if delay == 250 then
        callback()
      elseif delay == 100 then
        callback()
      end
    end
    vim.wait = function()
      wait_calls = wait_calls + 1
      return true
    end

    local ok, err = pcall(edit_jump.on_edit, {
      data = {
        file_path = path,
        starting_line = 2,
      },
    })

    vim.defer_fn = old_defer_fn
    vim.wait = old_wait
    edit_jump.jump_win = old_jump_win
    assert.is_true(ok, tostring(err))
    assert.are.equal(0, wait_calls, "an edit jump must not block the editor (vim.wait)")

    pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(path), { force = true })
    vim.fn.delete(path)
  end)

  it("on_diff_closed no longer exists (diff path removed)", function()
    assert.is_nil(edit_jump.on_diff_closed, "on_diff_closed should have been removed with the diff path")
  end)
end)

describe("edit-jump with zen mode open", function()
  local zen = require("zen-mode")
  local zen_view = require("zen-mode.view")

  local function write_file(suffix, n)
    local path = vim.fn.tempname() .. suffix
    local lines = {}
    for i = 1, n do
      lines[i] = "line " .. i
    end
    vim.fn.writefile(lines, path)
    return path
  end

  local function jump(path, line)
    edit_jump.on_edit({ data = { file_path = path, starting_line = line } })
    vim.wait(800)
  end

  it(
    "Given zen is open on file A, When the harness edits file B, Then the zen view shows B at the edit line",
    function()
      local a = write_file("-zen-a.txt", 10)
      local b = write_file("-zen-b.txt", 10)
      vim.cmd("edit " .. vim.fn.fnameescape(a))
      zen.open()
      assert.is_true(zen_view.is_open() == true, "test setup: zen should be open")

      jump(b, 4)

      local zwin = zen_view.win
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(zwin))
      local line = vim.api.nvim_win_get_cursor(zwin)[1]
      zen.close()
      vim.fn.delete(a)
      vim.fn.delete(b)

      assert.are.equal(vim.uv.fs_realpath(b), vim.uv.fs_realpath(name))
      assert.are.equal(4, line)
    end
  )

  it(
    "Given zen is open on file A, When the harness edits file A further down, Then the zen view's cursor moves to the edit line",
    function()
      local a = write_file("-zen-same.txt", 20)
      vim.cmd("edit " .. vim.fn.fnameescape(a))
      zen.open()
      assert.is_true(zen_view.is_open() == true, "test setup: zen should be open")
      vim.api.nvim_win_set_cursor(zen_view.win, { 1, 0 })

      jump(a, 15)

      local line = vim.api.nvim_win_get_cursor(zen_view.win)[1]
      zen.close()
      vim.fn.delete(a)

      assert.are.equal(15, line)
    end
  )
end)

-- Pins the dedup rules for edit records of the same file inside the 5s window.
describe("edit-jump: edit record dedup within 5s", function()
  local utils = require("harness-decorators.utils")
  local orig_extract
  local sid = "dedup-session"
  local path

  before_each(function()
    orig_extract = utils.extract_session_id
    utils.extract_session_id = function()
      return sid
    end
    edit_jump.edit_sources[sid] = nil
    path = vim.fn.tempname() .. "-dedup.txt"
    vim.fn.writefile({ "a", "b", "c" }, path)
  end)

  after_each(function()
    vim.wait(400)
    utils.extract_session_id = orig_extract
    edit_jump.edit_sources[sid] = nil
    vim.fn.delete(path)
  end)

  local function edit(fields)
    local data = { file_path = path, jsonl_path = "/x.jsonl" }
    for k, v in pairs(fields) do
      data[k] = v
    end
    edit_jump.on_edit({ data = data })
  end

  it("keeps the record that has a line when the new one has none", function()
    edit({ starting_line = 2, event_id = "first" })
    edit({ event_id = "second" })
    local list = edit_jump.edit_sources[sid]
    assert.are.equal(1, #list)
    assert.are.equal("first", list[1].event_id)
  end)

  it("upgrades in place when the new record has a line", function()
    edit({ source_line = 7, event_id = "first" })
    edit({ starting_line = 3, event_id = "second" })
    local list = edit_jump.edit_sources[sid]
    assert.are.equal(1, #list)
    assert.are.equal("second", list[1].event_id)
    assert.are.equal(3, list[1].starting_line)
  end)

  it("replaces in place when neither record has a line", function()
    edit({ event_id = "first" })
    edit({ event_id = "second" })
    local list = edit_jump.edit_sources[sid]
    assert.are.equal(1, #list)
    assert.are.equal("second", list[1].event_id)
  end)

  it("appends when the last has a source_line and the new one has no line", function()
    edit({ source_line = 7, event_id = "first" })
    edit({ event_id = "second" })
    assert.are.equal(2, #edit_jump.edit_sources[sid])
  end)
end)
