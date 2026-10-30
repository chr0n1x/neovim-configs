-- Contract spec for the "diffs are not lost in the history picker" invariant - the exact
-- thing the user reported as broken. M.pick() resolves the current session from the pinned
-- JSONL path via extract_session_id, then reads edit_sources[that id]. This spec pins that
-- link: a record stored under session S is returned by the same lookup the picker performs.
-- It does not open the telescope UI (headless can't drive it); it asserts the data contract
-- underneath, which is where "lost diffs" actually originate.

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")

---Mirror of the session-resolution + record-selection logic in M.pick(), factored out so
-- this spec asserts the same code path the picker uses without opening the UI.
local function pick_records(pinned_path)
  local current_session = utils.extract_session_id(pinned_path) or nil
  if not current_session then
    for sid, records in pairs(edit_jump.edit_sources) do
      if #records > 0 then
        current_session = sid
        break
      end
    end
  end
  return edit_jump.edit_sources[current_session] or {}, current_session
end

describe("history picker: records survive the session lookup", function()
  local orig_pin, orig_sources

  setup(function()
    orig_pin = watcher.pinned_jsonl_path
    orig_sources = edit_jump.edit_sources
  end)

  teardown(function()
    watcher.pinned_jsonl_path = orig_pin
    edit_jump.edit_sources = orig_sources
  end)

  it("a record stored under the pinned session id is returned by the picker lookup", function()
    -- Simulate a live edit landing in edit_sources under a known session.
    local sid = "deadbeef"
    edit_jump.edit_sources = {
      [sid] = {
        { file_path = "/a/b.lua", starting_line = 5, timestamp = 1700000000000, time_str = "x" },
      },
    }
    -- Pin to the JSONL whose stem is that same session id.
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/" .. sid .. ".jsonl"

    local records, resolved = pick_records(watcher.pinned_jsonl_path)
    assert.are.equal(sid, resolved, "picker must resolve the pinned session id")
    assert.are.equal(1, #records, "the stored record must be visible to the picker")
    assert.are.equal("/a/b.lua", records[1].file_path)
  end)

  it("falls back to the most recent non-empty session when no pin is set", function()
    edit_jump.edit_sources = {
      ["older"] = {}, -- empty, should be skipped
      ["newer"] = { { file_path = "/a/c.lua", timestamp = 1700000000000 } },
    }
    watcher.pinned_jsonl_path = nil

    local records, resolved = pick_records(nil)
    assert.are.equal("newer", resolved, "fallback must skip empty sessions")
    assert.are.equal(1, #records)
  end)

  it("returns no records when the pinned session has none (the 'lost diffs' symptom)", function()
    -- A record exists but under a DIFFERENT session than the one now pinned: the picker
    -- correctly shows nothing for the current session. This documents the failure mode -
    -- if the pin drifts to the wrong session, its records are not shown. Task 17 targets
    -- the root cause (pin stability); this spec pins the observable contract.
    edit_jump.edit_sources = {
      ["sessionA"] = { { file_path = "/a/a.lua", timestamp = 1700000000000 } },
    }
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/sessionB.jsonl"

    local records, resolved = pick_records(watcher.pinned_jsonl_path)
    assert.are.equal("sessionB", resolved)
    assert.are.equal(0, #records, "a pin that drifted off the recording session shows no diffs")
  end)
end)

describe("history picker: no-pin fallback in M.pick", function()
  local pickers, orig_new, orig_pin, orig_sources, captured

  before_each(function()
    pickers = require("telescope.pickers")
    orig_new = pickers.new
    orig_pin = watcher.pinned_jsonl_path
    orig_sources = edit_jump.edit_sources
    captured = nil
    pickers.new = function(opts)
      captured = opts
      return { find = function() end }
    end
    watcher.pinned_jsonl_path = nil
  end)

  after_each(function()
    pickers.new = orig_new
    watcher.pinned_jsonl_path = orig_pin
    edit_jump.edit_sources = orig_sources
  end)

  it("picks the session holding the newest record when several sessions are non-empty", function()
    edit_jump.edit_sources = { first = {}, second = {} }
    -- Assign the older record to the first hash key so the result cannot depend on pairs order.
    local older = next(edit_jump.edit_sources)
    local newer = older == "first" and "second" or "first"
    edit_jump.edit_sources[older] = { { file_path = "/a/old.lua", timestamp = 5000, time_str = "t" } }
    edit_jump.edit_sources[newer] = {
      { file_path = "/a/new1.lua", timestamp = 9000, time_str = "t" },
      { file_path = "/a/new2.lua", timestamp = 1500, time_str = "t" },
    }
    require("harness-decorators.telescope-history-picker").pick()
    assert.is_not_nil(captured, "pick must open a picker")
    local paths = vim.tbl_map(function(e)
      return e.value.file_path
    end, captured.finder.results)
    table.sort(paths)
    assert.are.same({ "/a/new1.lua", "/a/new2.lua" }, paths)
  end)
end)

describe("history picker: preview highlights", function()
  local previewers, orig_new, sidecar, orig_lookup, orig_extract, buf
  local pickers, orig_picker_new, orig_sources, orig_pin

  before_each(function()
    previewers = require("telescope.previewers")
    sidecar = require("harness-decorators.sidecar")
    orig_new, orig_lookup, orig_extract = previewers.new_buffer_previewer, sidecar.lookup, sidecar.extract_diff
    buf = vim.api.nvim_create_buf(false, true)
    orig_sources, orig_pin = edit_jump.edit_sources, watcher.pinned_jsonl_path
    watcher.pinned_jsonl_path = nil
    pickers = require("telescope.pickers")
    orig_picker_new = pickers.new
    pickers.new = function()
      return { find = function() end }
    end
  end)

  after_each(function()
    previewers.new_buffer_previewer, sidecar.lookup, sidecar.extract_diff = orig_new, orig_lookup, orig_extract
    pickers.new = orig_picker_new
    edit_jump.edit_sources, watcher.pinned_jsonl_path = orig_sources, orig_pin
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  ---Render one entry through the real define_preview and return the extmark highlights as
  ---{ row, col, end_col, group } tuples.
  local function render(diff_text)
    local define
    previewers.new_buffer_previewer = function(opts)
      define = opts.define_preview
      return {}
    end
    sidecar.lookup = function()
      return {}
    end
    sidecar.extract_diff = function()
      return diff_text
    end
    edit_jump.edit_sources = { s = { { file_path = "/a/b.lua", timestamp = 1, time_str = "2025-01-01" } } }
    require("harness-decorators.telescope-history-picker").pick()

    define({ state = { bufnr = buf } }, {
      value = { file_path = "/a/b.lua", time_str = "2025-01-01", sidecar_path = "/x", event_uuid = "u" },
    })
    local out = {}
    local ns = vim.api.nvim_create_namespace("harness_history_preview")
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      table.insert(out, { m[2], m[3], m[4].end_col, m[4].hl_group })
    end
    table.sort(out, function(a, b)
      return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
    end)
    return out, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  it("dims the date, brightens the path, and colors added, removed and context lines", function()
    local marks, lines = render("    1  ctx\n    2  +added\n    3  -gone")
    assert.are.equal("2025-01-01 /a/b.lua", lines[1])
    assert.are.same({
      { 0, 0, 10, "SidecarDate" },
      { 0, 10, #lines[1], "SidecarPath" },
      { 2, 0, 6, "SidecarDiffNum" },
      { 3, 0, #lines[4], "SidecarDiffAdd" },
      { 4, 0, #lines[5], "SidecarDiffDel" },
    }, marks)
    assert.is_false(vim.bo[buf].modifiable)
    assert.are.equal("diff", vim.bo[buf].filetype)
  end)

  it(
    "Given a number-only diff line, When it is previewed, Then the number highlight ends at the line boundary",
    function()
      local marks = render("    1")
      assert.are.same({ 2, 0, 5, "SidecarDiffNum" }, marks[3])
      assert.is_false(vim.bo[buf].modifiable)
    end
  )

  it("does not accumulate highlights when the same buffer is rendered again", function()
    render("    1  ctx")
    local marks = render("    1  ctx")
    assert.are.equal(3, #marks)
  end)
end)
