-- Specs for the claude adapter's JSONL dialect: parse_tool_result (the source of every
-- HarnessEdit) and extract_diff (the picker preview). These pin the exact fields the rest of
-- the stack consumes - file_path, operation, starting_line, dedup_key - so a dialect change
-- that silently drops a field fails here instead of surfacing as "no diffs in the picker".

local claude = require("harness-decorators.claude")

local function edit_line(uuid)
  local fp = vim.uv.cwd() .. "/tests/_claude_parse_target.txt"
  return string.format(
    '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a"," b","+ added line"," c"]}]}}',
    uuid, fp)
end

local function create_line(uuid)
  local fp = vim.uv.cwd() .. "/tests/_claude_create_target.txt"
  return string.format(
    '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"type":"create","content":"line1\\nline2"}}',
    uuid, fp)
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

  it("returns nil for a non-tool line", function()
    assert.is_nil(claude.parse_tool_result('{"type":"assistant","message":{"role":"assistant"}}', 1))
  end)

  it("returns nil for a noise filePath (temp/swap)", function()
    local fp = "/tmp/something.tmp"
    local line = string.format(
      '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a","+ b"]}]}}',
      "u3", fp)
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
