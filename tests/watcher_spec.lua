-- Integration spec for the watcher's dispatch path: a parsed JSONL tool result must reach
-- the HarnessEdit autocmd with the correct fields, and duplicate events (same dedup_key) must
-- fire exactly once. We drive watcher.process_recovered_lines - the same parse + dispatch path
-- live writes use - rather than spawning a real inotifywait, so no terminal mode is needed.
--
-- The real on_edit (which stores into edit_sources and jumps) is registered by
-- setup_auto_follow on the first <leader>c press; that never happens headless, so this spec
-- registers its own HarnessEdit handler to capture the dispatched data. That still exercises
-- the full dispatch_change -> nvim_exec_autocmds("User", "HarnessEdit") path, which is where a
-- regression would drop diffs before they ever reach the picker.

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")

-- A minimal claude toolUseResult line: an Edit with a structuredPatch whose first changed
-- line is at newStart + 2 (newStart points at the first CONTEXT line, so two context rows
-- precede the '+'). filePath under the real cwd so it is not noise and is unambiguous.
local function edit_line(uuid)
  local fp = vim.uv.cwd() .. "/tests/_watcher_dispatch_target.txt"
  return string.format(
    '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a"," b","+ added line"," c"]}]}}',
    uuid, fp)
end

describe("watcher dispatch: HarnessEdit fires with the parsed fields", function()
  local group
  local seen = {}
  local orig_harness, orig_pin

  setup(function()
    -- Only meaningful for the claude dialect; skip cleanly if CI runs another harness.
    assert.are.equal("claude", utils.harness, "watcher dispatch spec assumes the claude adapter")

    orig_harness = utils.harness
    orig_pin = watcher.pinned_jsonl_path
    -- Fresh dedup state so a prior spec's seen keys can't suppress our events.
    utils.reset_dedup()

    group = vim.api.nvim_create_augroup("WatcherDispatchSpec", { clear = true })
    seen = {}
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "HarnessEdit",
      callback = function(args)
        table.insert(seen, args.data)
      end,
    })
  end)

  teardown(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    utils.harness = orig_harness
    watcher.pinned_jsonl_path = orig_pin
    utils.reset_dedup()
  end)

  it("a toolUseResult line dispatches one HarnessEdit with the parsed fields", function()
    -- Pin to a synthetic session so any downstream store would key off a known id.
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/deadbeef.jsonl"

    watcher.process_recovered_lines({ edit_line("uuid-1") }, 0)

    assert.are.equal(1, #seen, "expected exactly one HarnessEdit autocmd")
    local d = seen[1]
    assert.are.equal("Edit", d.operation)
    -- newStart=1 points at the first CONTEXT line (" a"); " b" is line 2 (context), and the
    -- '+' lands on line 3. So starting_line = newStart + 2 for this fixture.
    assert.are.equal(3, d.starting_line)
    assert.are.equal("uuid-1", d.event_uuid)
    -- The jsonl_path in the payload is the pinned path - the field store_edit_source uses to
    -- derive the session id (see history_picker_spec).
    assert.are.equal(watcher.pinned_jsonl_path, d.jsonl_path)
  end)

  it("a duplicate event (same dedup_key) fires exactly once", function()
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/cafebabe.jsonl"
    utils.reset_dedup()
    seen = {}

    -- Distinct uuid first so the prior test's seen key can't suppress it.
    watcher.process_recovered_lines({ edit_line("uuid-first") }, 0)
    assert.are.equal(1, #seen, "first event should fire once")

    -- Now feed the same line twice with an identical uuid => identical dedup_key. The second
    -- dispatch must be suppressed (dedup), so no additional HarnessEdit fires.
    watcher.process_recovered_lines({ edit_line("uuid-dup") }, 0)
    watcher.process_recovered_lines({ edit_line("uuid-dup") }, 0)
    assert.are.equal(2, #seen, "the duplicate dedup_key must not fire twice (only the first)")
  end)

  it("does not dispatch a line that parses to no change", function()
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/deadbeef.jsonl"
    seen = {}
    -- A plain assistant line with no tool result: parse_tool_result returns nil, no dispatch.
    watcher.process_recovered_lines({ '{"type":"assistant","message":{"role":"assistant"}}' }, 0)
    assert.are.equal(0, #seen, "a non-tool line must not fire HarnessEdit")
  end)
end)
