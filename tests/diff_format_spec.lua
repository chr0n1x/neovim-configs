-- Guards the diff output format that the history picker's highlighter parses.
--
-- telescope-history-picker.lua reads each diff line as "%5d  <prefix><content>" and finds
-- the prefix char at string position 8 (1-indexed): "+" = addition, "-" = deletion,
-- anything else = context. diff.diff_full_files is the single producer of that format
-- (shared by maki and copilot), so a change to its format string silently breaks the
-- picker's highlighting. This spec pins the contract with a few concrete cases.

local diff = require("harness-decorators.diff")

describe("diff.diff_full_files output format (picker contract)", function()
  it("emits lines of the form '%5d  <prefix><content>' with the prefix at position 8", function()
    local before = "a\nb\nc\nd\ne"
    local after = "a\nB\nc\nd\ne" -- line 2 changed
    local lines = diff.diff_full_files(before, after)
    assert.is_truthy(#lines > 0, "expected at least one diff line")
    for _, line in ipairs(lines) do
      -- %5d right-justifies the number in 5 chars, then two spaces, so the prefix char is
      -- always at string position 8 (the picker reads line:sub(8,8)). Positions 6-7 are the
      -- two separator spaces; positions 1-5 hold the zero-padded line number.
      assert.is_truthy(#line >= 8, ("line too short to carry a prefix at position 8: %q"):format(line))
      assert.are.equal("  ", line:sub(6, 7), ("positions 6-7 must be two spaces (got %q in %q)"):format(line:sub(6, 7), line))
      -- The number field is digits (right-justified, so it may have leading spaces).
      assert.is_truthy(line:sub(1, 5):match("^%s*%d+$"), ("positions 1-5 must be a right-justified integer: %q"):format(line))
    end
  end)

  it("marks a changed line with '-' (old) and '+' (new) prefixes", function()
    local before = "a\nb\nc"
    local after = "a\nX\nc"
    local lines = diff.diff_full_files(before, after)
    -- The old line 2 is a deletion ('-' at position 8), the new line 2 an addition ('+' at
    -- position 8).
    local has_del_b, has_add_x = false, false
    for _, line in ipairs(lines) do
      if line:sub(8, 8) == "-" and line:find("b", 1, true) then
        has_del_b = true
      end
      if line:sub(8, 8) == "+" and line:find("X", 1, true) then
        has_add_x = true
      end
    end
    assert.is_truthy(has_del_b, ("expected a '-' deletion of 'b':\n" .. table.concat(lines, "\n")):gsub("\n", "\n  "))
    assert.is_truthy(has_add_x, ("expected a '+' addition of 'X':\n" .. table.concat(lines, "\n")):gsub("\n", "\n  "))
  end)

  it("marks unchanged lines with a space (context) prefix", function()
    local before = "a\nb\nc"
    local after = "a\nB\nc"
    local lines = diff.diff_full_files(before, after)
    -- Line 1 ('a') and line 3 ('c') are context: prefix char is a space at position 8.
    local function context_of(idx_content)
      for _, line in ipairs(lines) do
        if line:sub(8, 8) == " " and line:find(idx_content, 1, true) then
          return true
        end
      end
      return false
    end
    assert.is_truthy(context_of("a"), "expected 'a' as a context (space-prefixed) line")
    assert.is_truthy(context_of("c"), "expected 'c' as a context (space-prefixed) line")
  end)

  it("find_starting_line returns the first divergent 1-based line", function()
    assert.are.equal(2, diff.find_starting_line("a\nb\nc", "a\nX\nc"))
    assert.are.equal(1, diff.find_starting_line("a\nb", "Z\nb"))
    -- Boundary change (insertion): all common lines match, lengths differ.
    assert.are.equal(3, diff.find_starting_line("a\nb", "a\nb\nc"))
    -- Identical: no change.
    assert.is_nil(diff.find_starting_line("a\nb", "a\nb"))
  end)
end)
