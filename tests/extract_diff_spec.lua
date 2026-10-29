-- Pins the extract_diff text for copilot (old_str/new_str) and maki (Diff before/after):
-- "N -> M lines", a blank line, then diff.diff_full_files output.

local diff = require("harness-decorators.diff")

local before = "a\nb\nc"
local after = "a\nB\nc\nd"
local expected = "3 -> 4 lines\n\n" .. table.concat(diff.diff_full_files(before, after), "\n")

describe("extract_diff full-file format", function()
  it("copilot: header, blank line, numbered diff", function()
    local copilot = require("harness-decorators.copilot")
    local out = copilot.extract_diff({ data = { arguments = { old_str = before, new_str = after } } })
    assert.are.equal(expected, out)
  end)

  it("maki: header, blank line, numbered diff", function()
    local maki = require("harness-decorators.maki")
    local out = maki.extract_diff({ d = { Diff = { before = before, after = after } } })
    assert.are.equal(expected, out)
  end)

  it("identical content still lists the unchanged line as context", function()
    local copilot = require("harness-decorators.copilot")
    local out = copilot.extract_diff({ data = { arguments = { old_str = "x", new_str = "x" } } })
    assert.are.equal("1 -> 1 lines\n\n    1   x", out)
  end)
end)
