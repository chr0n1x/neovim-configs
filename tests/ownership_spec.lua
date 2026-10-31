-- Spec for the watcher's session-pin logic (Task 17, Option B): the pin locks on the
-- sessionId DECLARED inside the JSONL, not on cwd. Cwd is only the initial candidate filter;
-- once a file declares an id we key on that id so a stale same-cwd session cannot hijack the
-- pin. A genuine mid-work switch (a different declared id writing) re-pins and PRESERVES the
-- old session's edit history.
--
-- We drive M.process_jsonl_write against real temp JSONL files (claude dialect: each line
-- carries "cwd" and "sessionId"). No inotifywait backend is spawned, so the spec runs fast.
--
-- Pin timing note: the first-encounter path checks ownership with EMPTY lines (it has not yet
-- read file content), so a fresh file is always "unknown" on its first write and does NOT pin.
-- The pin happens on the SECOND write, when the incremental path reads the new chunk and sees
-- the declared id. Hence every fixture appends two lines before asserting the pin.

local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")

-- A claude-style line: top-level cwd + sessionId. Both carries the same id so a two-line
-- fixture declares one session unambiguously.
local function claude_line(session_id, cwd)
  return string.format('{"type":"user","cwd":%q,"sessionId":%q}', cwd, session_id)
end

local tmpdir = vim.fn.tempname() .. "-ownership"

describe("watcher session pin (Option B: pin by declared session id)", function()
  local cwd
  local file_a, file_b

  setup(function()
    assert.are.equal("claude", active.get(), "ownership spec assumes the claude adapter")
    vim.fn.mkdir(tmpdir, "p")
    -- Ownership is checked against watcher.nvim_cwd (captured at watcher start). Headless
    -- specs never call start(), so set it explicitly; both files declare this same cwd.
    cwd = vim.uv.cwd()
    watcher.nvim_cwd = cwd
    file_a = tmpdir .. "/session-a.jsonl"
    file_b = tmpdir .. "/session-b.jsonl"
  end)

  teardown(function()
    watcher.reset_all()
    watcher.nvim_cwd = nil
    active.set("claude")
    vim.fn.delete(tmpdir, "rf")
  end)

  local function append(path, lines)
    local f = assert(io.open(path, "a"))
    for _, line in ipairs(lines) do
      f:write(line .. "\n")
    end
    f:close()
  end

  -- Two writes: first records position (ownership unknown), second reads the chunk and pins.
  local function pin_session(path, session_id)
    append(path, { claude_line(session_id, cwd) })
    watcher.process_jsonl_write(path)
    append(path, { claude_line(session_id, cwd) })
    watcher.process_jsonl_write(path)
  end

  it("pins on the declared sessionId, not cwd", function()
    pin_session(file_a, "aaaa1111")

    assert.are.equal(file_a, watcher.pinned_jsonl_path)
    -- The pin key is the id the file declared, not a path-derived stem.
    assert.are.equal("aaaa1111", watcher.pinned_session_id)
  end)

  it("a stale same-cwd session cannot hijack the pin once a different id is pinned", function()
    pin_session(file_a, "aaaa1111")
    assert.are.equal("aaaa1111", watcher.pinned_session_id)

    -- Session B: same cwd, different declared id. Once A is pinned, B's writes must NOT re-pin.
    append(file_b, { claude_line("bbbb2222", cwd) })
    watcher.process_jsonl_write(file_b)
    append(file_b, { claude_line("bbbb2222", cwd) })
    watcher.process_jsonl_write(file_b)

    assert.are.equal(file_a, watcher.pinned_jsonl_path, "pin must stay on session A")
    assert.are.equal("aaaa1111", watcher.pinned_session_id)
  end)

  it("a different declared id re-pins when the pinned path itself switches sessions", function()
    pin_session(file_a, "aaaa1111")
    assert.are.equal("aaaa1111", watcher.pinned_session_id)

    -- Simulate /resume: the SAME pinned file now declares a NEW session id. The incremental
    -- path sees this_id ~= pinned_session_id and re-pins to it.
    append(file_a, { claude_line("bbbb2222", cwd) })
    watcher.process_jsonl_write(file_a)

    assert.are.equal(file_a, watcher.pinned_jsonl_path)
    assert.are.equal("bbbb2222", watcher.pinned_session_id, "pin must move to the new declared id")
  end)

  it("re-pinning preserves the old session's edit history (edit_sources)", function()
    pin_session(file_a, "aaaa1111")
    -- Record an edit under the pinned session.
    edit_jump.edit_sources["aaaa1111"] = { { file_path = "/tmp/x" } }

    -- Switch to a new declared id on the same path.
    append(file_a, { claude_line("bbbb2222", cwd) })
    watcher.process_jsonl_write(file_a)
    assert.are.equal("bbbb2222", watcher.pinned_session_id)

    -- The old session's history must survive the switch (user chose "preserve old history").
    assert.is_not_nil(edit_jump.edit_sources["aaaa1111"], "old session history must be preserved")
  end)

  it("a same-id write from a different path does not re-pin", function()
    pin_session(file_a, "aaaa1111")
    assert.are.equal(file_a, watcher.pinned_jsonl_path)

    -- file_b declares the SAME id as the pinned one but is a different path. The incremental
    -- path sees this_id == pinned_session_id, so it must NOT move the pin off file_a.
    append(file_b, { claude_line("aaaa1111", cwd) })
    watcher.process_jsonl_write(file_b)
    append(file_b, { claude_line("aaaa1111", cwd) })
    watcher.process_jsonl_write(file_b)

    assert.are.equal(file_a, watcher.pinned_jsonl_path, "same id from another path must not move the pin")
  end)
end)

-- What the watcher does for an adapter that leaves the optional pin hooks to the stub base:
-- claude with its own session_id_from_lines removed, and claude as-is (it has no on_pin).
describe("watcher pin with the stub base's optional fields", function()
  local adapter, cwd, dir, group, seen
  local orig = {}

  local function append(path, lines)
    local f = assert(io.open(path, "a"))
    for _, line in ipairs(lines) do
      f:write(line .. "\n")
    end
    f:close()
  end

  local function edit_line(uuid)
    local fp = vim.uv.cwd() .. "/tests/_watcher_dispatch_target.txt"
    return string.format(
      '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a"," b","+ added line"," c"]}]}}',
      uuid,
      fp
    )
  end

  before_each(function()
    assert.are.equal("claude", active.get(), "ownership spec assumes the claude adapter")
    watcher.set_harness("claude")
    adapter = require("harness-decorators.claude")
    orig.session_id_from_lines = rawget(adapter, "session_id_from_lines")
    orig.session_ownership = rawget(adapter, "session_ownership")
    watcher.reset_all()
    utils.reset_dedup()
    cwd = vim.uv.cwd()
    watcher.nvim_cwd = cwd
    dir = vim.fn.tempname() .. "-stub-fields"
    vim.fn.mkdir(dir, "p")
    seen = {}
    group = vim.api.nvim_create_augroup("OwnershipStubFieldsSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "HarnessEdit",
      callback = function(args)
        table.insert(seen, args.data)
      end,
    })
  end)

  after_each(function()
    adapter.session_id_from_lines = orig.session_id_from_lines
    adapter.session_ownership = orig.session_ownership
    pcall(vim.api.nvim_del_augroup_by_id, group)
    watcher.reset_all()
    watcher.nvim_cwd = nil
    utils.reset_dedup()
    vim.fn.delete(dir, "rf")
  end)

  it(
    "Given no own session_id_from_lines, When cwd-matching lines arrive after an unknown first encounter, Then the file pins keyed by the filename stem",
    function()
      adapter.session_id_from_lines = nil
      local path = dir .. "/stem-1234.jsonl"
      append(path, { claude_line("declared-id", cwd) })
      watcher.process_jsonl_write(path)
      assert.is_nil(watcher.pinned_jsonl_path, "the first encounter is unknown")
      append(path, { claude_line("declared-id", cwd) })
      watcher.process_jsonl_write(path)
      assert.are.equal(path, watcher.pinned_jsonl_path)
      assert.are.equal("stem-1234", watcher.pinned_session_id)
    end
  )

  it(
    "Given no own session_id_from_lines, When a file pins on first encounter, Then the key is the filename stem",
    function()
      adapter.session_id_from_lines = nil
      adapter.session_ownership = function()
        return "match"
      end
      local path = dir .. "/stem-1234.jsonl"
      append(path, { claude_line("declared-id", cwd) })
      watcher.process_jsonl_write(path)
      append(path, { claude_line("declared-id", cwd) })
      watcher.process_jsonl_write(path)
      assert.are.equal(path, watcher.pinned_jsonl_path)
      assert.are.equal("stem-1234", watcher.pinned_session_id)
    end
  )

  it("Given no own on_pin, When a file pins on first encounter, Then existing lines are not replayed", function()
    assert.is_nil(rawget(adapter, "on_pin"))
    adapter.session_ownership = function()
      return "match"
    end
    local path = dir .. "/first-pin.jsonl"
    append(path, { edit_line("old-1"), edit_line("old-2") })
    watcher.process_jsonl_write(path)
    assert.are.equal(path, watcher.pinned_jsonl_path, "first encounter pins on a match")
    assert.are.equal(0, #seen, "lines written before the pin are not dispatched")
    append(path, { edit_line("new-1") })
    watcher.process_jsonl_write(path)
    assert.are.equal(1, #seen)
    assert.are.equal("new-1", seen[1].event_uuid)
  end)
end)

-- Copilot declares no session id inside its lines; the id is the parent dir of events.jsonl.
describe("watcher pin for copilot", function()
  local dir, cwd
  local sid = "cccc3333"

  before_each(function()
    watcher.set_harness("copilot")
    cwd = vim.uv.cwd()
    watcher.nvim_cwd = cwd
    dir = vim.fn.tempname() .. "-copilot-pin"
    vim.fn.mkdir(dir .. "/" .. sid, "p")
  end)

  after_each(function()
    watcher.set_harness("claude")
    watcher.nvim_cwd = nil
    vim.fn.delete(dir, "rf")
  end)

  it(
    "Given copilot, When events.jsonl is first seen before its ownership can be decided and a later write arrives once it matches, Then the session pins",
    function()
      local path = dir .. "/" .. sid .. "/events.jsonl"
      local f = assert(io.open(path, "w"))
      f:close()
      watcher.process_jsonl_write(path)
      assert.is_nil(watcher.pinned_jsonl_path, "precondition: ownership is unknown on first encounter")

      f = assert(io.open(path, "a"))
      f:write(vim.json.encode({ type = "session.start", data = { context = { cwd = cwd } } }) .. "\n")
      f:write('{"type":"user.message"}\n')
      f:close()
      watcher.process_jsonl_write(path)

      assert.are.equal(path, watcher.pinned_jsonl_path)
      assert.are.equal(sid, watcher.pinned_session_id)
    end
  )
end)
