-- Specs for the claude adapter's JSONL dialect: parse_tool_result (the source of every
-- HarnessEdit) and extract_diff (the picker preview). These pin the exact fields the rest of
-- the stack consumes - file_path, operation, starting_line, dedup_key - so a dialect change
-- that silently drops a field fails here instead of surfacing as "no diffs in the picker".

local claude = require("harness-decorators.claude")

local function edit_line(uuid)
  local fp = vim.uv.cwd() .. "/tests/_claude_parse_target.txt"
  return string.format(
    '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a"," b","+ added line"," c"]}]}}',
    uuid,
    fp
  )
end

local function create_line(uuid)
  local fp = vim.uv.cwd() .. "/tests/_claude_create_target.txt"
  return string.format(
    '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"type":"create","content":"line1\\nline2"}}',
    uuid,
    fp
  )
end

describe("claude.parse_tool_result", function()
  it("parses an Edit toolUseResult with the changed starting_line", function()
    local ci = claude.parse_tool_result(edit_line("u1"), 42)
    assert.is_not_nil(ci, "expected a change_info for a valid toolUseResult line")
    assert.are.equal("Edit", ci.operation)
    -- newStart=1 is the first context line (" a"); " b" is line 2 (context), '+' lands on 3.
    assert.are.equal(3, ci.starting_line)
    assert.are.equal(42, ci.source_line)
    assert.are.equal("u1", ci.event_uuid)
    -- dedup_key must be present so duplicate dispatches are suppressed downstream.
    assert.is_not_nil(ci.dedup_key)
  end)

  it("parses a Create toolUseResult with operation=Create and no starting_line", function()
    local ci = claude.parse_tool_result(create_line("u2"), 7)
    assert.is_not_nil(ci)
    assert.are.equal("Create", ci.operation)
    assert.is_nil(ci.starting_line)
  end)

  it("labels an oldString/newString result and a type=update result as Edit", function()
    local fp = vim.uv.cwd() .. "/tests/_claude_edit_target.txt"
    local line = string.format(
      '{"type":"user","uuid":"u4","timestamp":1700000000000,"toolUseResult":{"filePath":%q,"oldString":"a","newString":"b"}}',
      fp
    )
    assert.are.equal("Edit", claude.parse_tool_result(line, 1).operation)
    local upd = string.format(
      '{"type":"user","uuid":"u5","timestamp":1700000000000,"toolUseResult":{"filePath":%q,"type":"update"}}',
      fp
    )
    assert.are.equal("Edit", claude.parse_tool_result(upd, 1).operation)
  end)

  it("returns nil for a non-tool line", function()
    assert.is_nil(claude.parse_tool_result('{"type":"assistant","message":{"role":"assistant"}}', 1))
  end)

  it("returns nil for a noise filePath (temp/swap)", function()
    local fp = "/tmp/something.tmp"
    local line = string.format(
      '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a","+ b"]}]}}',
      "u3",
      fp
    )
    assert.is_nil(claude.parse_tool_result(line, 1))
  end)

  it("returns nil for malformed JSON that merely mentions toolUseResult", function()
    assert.is_nil(claude.parse_tool_result('{"toolUseResult": not-json', 1))
  end)
end)

describe("claude.extract_diff (picker preview contract)", function()
  it("renders a numbered unified diff for a structuredPatch event", function()
    local ev = {
      toolUseResult = {
        filePath = "/x/y.lua",
        structuredPatch = {
          { oldStart = 1, oldLines = 3, newStart = 1, newLines = 4, lines = { " a", " b", "+ added", " c" } },
        },
      },
    }
    local text = claude.extract_diff(ev)
    assert.is_string(text)
    -- The picker strips the leading "N -> M lines" delta header and any blank line before it
    -- highlights, so validate only the numbered diff lines: "%5d  <prefix><content>" with the
    -- prefix at position 8. Skip non-numbered lines (the delta header) to mirror that strip.
    local saw_add = false
    for _, l in ipairs(vim.split(text, "\n")) do
      if #l >= 8 and l:sub(1, 5):match("^%s*%d+$") then
        assert.are.equal("  ", l:sub(6, 7), "positions 6-7 must be two spaces: " .. l)
        if l:sub(8, 8) == "+" and l:find("added", 1, true) then
          saw_add = true
        end
      end
    end
    assert.is_true(saw_add, "expected a '+' addition line for 'added'")
  end)

  it("returns a placeholder when there is no diff data", function()
    assert.are.equal("(no diff data available)", claude.extract_diff(nil))
    -- An event with no toolUseResult reaches the generic "matched but empty" placeholder.
    assert.are.equal("(event matched but contains no diff data)", claude.extract_diff({}))
  end)
end)

describe("adapter default fields (stub base contract)", function()
  local NO_DIFF = "(no diff data available)"
  local NO_EVENT_DIFF = "(event matched but contains no diff data)"

  it("claude: own reset/ownership, stub-shaped defaults elsewhere", function()
    local a = require("harness-decorators.claude")
    assert.is_true(a.is_same_file_reset("/clear"))
    assert.is_false(a.is_same_file_reset("/new"))
    assert.are.equal("unknown", a.session_ownership(nil, {}))
    assert.are.equal(NO_DIFF, a.extract_diff(nil))
    assert.are.equal(NO_EVENT_DIFF, a.extract_diff({}))
    assert.is_nil(a.find_reset_command({}))
  end)

  it("copilot: no reset handling, no same-file reset", function()
    local a = require("harness-decorators.copilot")
    assert.is_nil(a.find_reset_command({ '{"type":"user","message":{"content":"/clear"}}' }))
    assert.is_false(a.is_same_file_reset("/clear"))
    assert.is_false(a.is_same_file_reset("/compact"))
    assert.are.equal(NO_DIFF, a.extract_diff(nil))
    assert.are.equal(NO_EVENT_DIFF, a.extract_diff({}))
  end)

  it("maki: /compact is the only same-file reset; reset scan and tool parse are inert", function()
    local a = require("harness-decorators.maki")
    assert.is_true(a.is_same_file_reset("/compact"))
    assert.is_false(a.is_same_file_reset("/clear"))
    assert.is_nil(a.find_reset_command({ '{"t":"user","text":"/new"}' }))
    assert.is_nil(a.parse_tool_result('{"toolUseResult":{}}', 1))
    assert.are.equal(NO_DIFF, a.extract_diff(nil))
    assert.are.equal(NO_EVENT_DIFF, a.extract_diff({}))
  end)

  for _, name in ipairs({ "crush", "pig", "pi" }) do
    it(name .. ": inert stub defaults", function()
      local a = require("harness-decorators." .. name)
      assert.is_nil(a.projects_dir())
      assert.are.equal("unknown", a.session_ownership("/a", { '{"cwd":"/a"}' }, "/x"))
      assert.is_nil(a.find_reset_command({ "/clear" }))
      assert.is_false(a.is_same_file_reset("/clear"))
      assert.is_nil(a.parse_tool_result("{}", 1))
    end)
  end

  -- Watcher-read fields each adapter overrides. Every other one comes from the stub base.
  local probed = {
    "on_pin",
    "inotify_events",
    "push_following",
    "session_id",
    "session_id_from_lines",
    "flat_sessions_dir",
    "on_activate",
  }
  local own = {
    claude = { session_id_from_lines = true },
    copilot = { session_id = true, session_id_from_lines = true, flat_sessions_dir = true },
    maki = { on_pin = true, session_id_from_lines = true, flat_sessions_dir = true },
    crush = {},
    pi = { push_following = true, session_id = true, on_activate = true },
    pig = {},
  }
  for name, fields in pairs(own) do
    it(name .. ": overrides exactly its own watcher-read fields and inherits the rest from the stub", function()
      local stub = require("harness-decorators.stub-adapter")
      local a = require("harness-decorators." .. name)
      assert.are.equal(stub, getmetatable(a).__index, name .. " must inherit from the stub base")
      for _, field in ipairs(probed) do
        if fields[field] then
          assert.is_not_nil(rawget(a, field), name .. "." .. field .. " should be overridden")
          if stub[field] ~= nil then
            assert.are.equal(type(stub[field]), type(rawget(a, field)), name .. "." .. field .. " has the stub's type")
          end
        else
          assert.is_nil(rawget(a, field), name .. "." .. field .. " should not be overridden")
          assert.are.equal(stub[field], a[field], name .. "." .. field .. " should be the stub's")
        end
      end
    end)
  end

  it("stub: watcher-read defaults behave as an adapter without the hook", function()
    local stub = require("harness-decorators.stub-adapter")
    assert.are.equal(42, stub.on_pin("/x.jsonl", 42))
    assert.is_nil(stub.session_id("/x/abc.jsonl"))
    assert.is_nil(stub.session_id_from_lines({ '{"sessionId":"s"}' }))
    assert.is_nil(stub.inotify_events())
    assert.is_false(stub.push_following)
    assert.is_false(stub.flat_sessions_dir)
    assert.is_nil(stub.on_activate)
  end)
end)
