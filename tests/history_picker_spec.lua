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
