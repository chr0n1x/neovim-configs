-- Spec for the <leader>cl picker's preview data path (Option A, Task 6; Task 7 rework).
--
-- The picker itself is telescope UI and can't be driven headless, but its preview pane is fed by
-- switch.collect_terminal_bufs(): a harness -> terminal-buffer map built entirely from the unified
-- park table, which is now backed by term.lua (one Snacks float per harness). That map is what lets
-- the preview show "what each harness is doing". This spec drives it directly: it opens fake per-
-- harness instances via term.open (Snacks.terminal.open stubbed to return windowless-buffer fakes),
-- so no real PTY or window is created in headless.
local helper = require("tests.helper")
local sw = require("harness-decorators.switch")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

describe("picker: collect_terminal_bufs maps harnesses to live buffers (Task 6/7)", function()
  local term_mod
  local snacks
  local orig_open
  local original_harness
  local orig_env

  ---A fake Snacks instance backed by a windowless buffer.
  local function make_fake(buf)
    return {
      buf = buf,
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
      buf_valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
    }
  end

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness")
    orig_env = os.getenv("NVIM_LLM_HARNESS")
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      return make_fake(vim.api.nvim_create_buf(false, true))
    end
    require("harness-decorators.state")._reset()
  end)

  teardown(function()
    if snacks then
      snacks.open = orig_open
    end
    require("harness-decorators.state")._reset()
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    utils.harness = original_harness
  end)

  it("includes a harness's live terminal buffer", function()
    -- Open the active harness's float; collect must map it to that buffer.
    local inst = term_mod.open(original_harness)
    local bufs = sw.collect_terminal_bufs()
    assert.are.equal(inst.buf, bufs[original_harness], "open harness's live buffer missing from map")
  end)

  it("includes a second (parked) harness's buffer independently", function()
    -- Two harnesses with two distinct floats: both must appear, each mapped to its OWN buffer.
    local a = term_mod.open(original_harness)
    local other = nil
    for _, h in ipairs(keymaps.list_harnesses()) do
      if h ~= original_harness then
        other = h
        break
      end
    end
    assert.is_not_nil(other, "no alternate harness to open")
    local b = term_mod.open(other)

    local bufs = sw.collect_terminal_bufs()
    assert.are.equal(a.buf, bufs[original_harness])
    assert.are.equal(b.buf, bufs[other], "second harness's buffer missing from map")
    assert.are_not.equal(a.buf, b.buf, "two harnesses must map to two distinct buffers")
  end)

  it("omits a harness that was never opened (no live buffer)", function()
    require("harness-decorators.state")._reset()
    local bufs = sw.collect_terminal_bufs()
    assert.are.equal(0, vim.tbl_count(bufs), "expected an empty map when nothing is open")
  end)

  it("drops an entry whose buffer has died", function()
    local inst = term_mod.open(original_harness)
    -- Kill the buffer: its process exited. collect must not offer it for preview.
    vim.api.nvim_buf_delete(inst.buf, { force = true })
    local bufs = sw.collect_terminal_bufs()
    assert.are_nil(bufs[original_harness], "dead buffer should not appear in the preview map")
  end)
end)

-- The picker entry is a plain table (marker + colored name), built by switch.make_entry. It can be
-- driven headless: no telescope UI, just the display() closure that returns the text and highlight
-- ranges. This spec asserts the three states - active / parked / never-opened - each render the
-- right glyph in its own color group, and that the name is always colored with its HarnessTitle<Name>
-- group (the glyph and the name are highlighted independently).
describe("picker: make_entry renders a colored state glyph + harness name (Task 9)", function()
  local title_mod

  setup(function()
    -- make_entry is pure (no state read/write), so no reset is needed here - and resetting would
    -- clear the selected-harness bit that <leader>c depends on for the rest of the in-process run.
    title_mod = require("harness-decorators.title")
  end)

  ---Collect the highlight ranges display() returns, keyed by group name.
  local function groups_of(name, current, bufs)
    local entry = sw.make_entry(name, current, bufs)
    local _, ranges = entry.display()
    local out = {}
    for _, r in ipairs(ranges or {}) do
      out[r[2]] = { start = r[1][1], stop = r[1][2] }
    end
    return out
  end

  it("marks an active harness WITH a live buffer with a filled circle in HarnessPickerActive", function()
    local g = groups_of("claude", "claude", { claude = 42 })
    assert.is_not_nil(g.HarnessPickerActive, "active glyph group missing")
    -- The glyph is "● " (a 4-byte UTF-8 circle + space); the name starts right after it.
    assert.are.equal(0, g.HarnessPickerActive.start)
    assert.are.equal(#("● "), g.HarnessPickerActive.stop)
    assert.is_not_nil(g.HarnessTitleClaude, "active name must still be colored")
  end)

  it("marks an active harness WITHOUT a live buffer (never initialized) with no glyph", function()
    local g = groups_of("claude", "claude", {})
    assert.is_nil(g.HarnessPickerActive, "uninitialized active harness must not show the active glyph")
    assert.is_nil(g.HarnessPickerParked, "uninitialized active harness must not show the parked glyph")
    -- Only the name is highlighted (no glyph group).
    assert.is_not_nil(g.HarnessTitleClaude, "name must still be colored")
  end)

  it("marks a parked harness (live buffer, not active) with a hollow circle in HarnessPickerParked", function()
    local g = groups_of("maki", "claude", { maki = 42 })
    assert.is_not_nil(g.HarnessPickerParked, "parked glyph group missing")
    assert.are.equal(0, g.HarnessPickerParked.start)
    assert.are.equal(#("○ "), g.HarnessPickerParked.stop)
    assert.is_not_nil(g.HarnessTitleMaki, "parked name must still be colored")
  end)

  it("marks a never-opened harness with two spaces and no state group", function()
    local g = groups_of("pi", "claude", {})
    assert.is_nil(g.HarnessPickerActive, "idle row must not use the active glyph")
    assert.is_nil(g.HarnessPickerParked, "idle row must not use the parked glyph")
    -- Only the name is highlighted.
    assert.is_not_nil(g.HarnessTitlePi, "idle name must still be colored")
  end)

  it("highlights the name starting right after the glyph", function()
    local g = groups_of("claude", "claude", { claude = 42 })
    -- The active glyph is "● " (4 bytes); 'claude' is 6 bytes, so the name spans [4, 10).
    assert.are.equal(#("● "), g.HarnessTitleClaude.start, "name should start right after the glyph")
    assert.are.equal(#("● ") + #("claude"), g.HarnessTitleClaude.stop)
  end)

  it("falls back to plain text when the harness has no title group", function()
    -- An unknown harness name has no HarnessTitle<Name> group; display must not error and returns
    -- just the text (no highlight ranges).
    local entry = sw.make_entry("unknown", "unknown", {})
    local text, ranges = entry.display()
    assert.is_string(text)
    assert.is_nil(ranges)
  end)
end)

-- The picker's static config (layout strategy + the three titles) is not observable without opening
-- telescope UI, so this spec stubs telescope.pickers to capture the opts M.pick() passes and asserts
-- on them. This keeps the layout/titles contract tested headless (Task 9).
describe("picker: M.pick uses a horizontal layout with the expected titles (Task 9)", function()
  local captured

  setup(function()
    captured = nil
    package.loaded["telescope.pickers"] = {
      new = function(_, opts)
        captured = opts
        return { find = function() end }
      end,
    }
  end)

  teardown(function()
    -- Restore the real telescope module. Do NOT reset the shared state table here: M.pick() only
    -- reads config (it never mutates selection), and wiping state would clear the selected-harness
    -- bit that <leader>c (park.show_selected) depends on - leaving <leader>c dead for the rest of
    -- the in-process session. Other specs manage their own selection via park.set_selected.
    package.loaded["telescope.pickers"] = nil
  end)

  it("uses the horizontal layout strategy with the prompt on the bottom", function()
    sw.pick()
    assert.is_not_nil(captured, "M.pick did not reach telescope.pickers.new")
    assert.are.equal("horizontal", captured.layout_strategy)
    assert.are.equal("bottom", captured.layout_config.prompt_position)
  end)

  it("titles the prompt 'search' and the results 'Harnesses'", function()
    sw.pick()
    assert.are.equal("search", captured.prompt_title)
    assert.are.equal("Harnesses", captured.results_title)
  end)

  it("titles the preview pane with a Preview label", function()
    sw.pick()
    -- The dynamic per-harness name is already rendered as the first line of the preview buffer, so a
    -- static "Preview" title is the pragmatic choice (telescope titles are set once at creation).
    assert.are.equal("Preview", captured.preview_title)
  end)
end)

describe("picker: preview_header sizes the header/separator to the pane width", function()
  -- Count UTF-8 characters in a string. `─` is 3 bytes (0xE2 0x94 0x80), so #str overcounts for
  -- strings containing it. This helper walks the string and counts each multi-byte sequence as one
  -- character.
  local function char_len(s)
    local count = 0
    local i = 1
    while i <= #s do
      local byte = s:byte(i)
      if byte < 0x80 then
        i = i + 1
      elseif byte < 0xE0 then
        i = i + 2
      elseif byte < 0xF0 then
        i = i + 3
      else
        i = i + 4
      end
      count = count + 1
    end
    return count
  end

  it("separator spans the full given width", function()
    local _, sep = sw.preview_header("claude", "active", 120)
    assert.are.equal(120, char_len(sep), "separator must be exactly as wide as the preview pane")
    -- Lua patterns don't handle multi-byte UTF-8 well, so verify by checking every 3-byte chunk
    -- is the box-drawing char E2 94 80.
    for i = 1, #sep, 3 do
      assert.are.equal(0xE2, sep:byte(i), "separator byte " .. i .. " must be 0xE2")
      assert.are.equal(0x94, sep:byte(i + 1), "separator byte " .. (i + 1) .. " must be 0x94")
      assert.are.equal(0x80, sep:byte(i + 2), "separator byte " .. (i + 2) .. " must be 0x80")
    end
  end)

  it("header label is padded to the full width", function()
    local header = sw.preview_header("claude", "active", 120)
    assert.are.equal(120, #header, "header row must span the full pane width (padded)")
    -- The header starts with "claude  (active)" followed by spaces; check the prefix using find.
    assert.is_not_nil(header:find("^claude  %(%a+%)%s*$"), "header must start with the name + status label")
  end)

  it("falls back to a default width when width is nil or non-positive", function()
    local _, sep_nil = sw.preview_header("maki", "backgrounded", nil)
    local _, sep_zero = sw.preview_header("maki", "backgrounded", 0)
    assert.are.equal(char_len(sep_nil), char_len(sep_zero), "nil and 0 widths must fall back to the same default")
    assert.is_true(char_len(sep_nil) > 0, "fallback separator must be non-empty")
  end)

  it("truncates an over-long label instead of overflowing the width", function()
    local header, sep = sw.preview_header(string.rep("x", 200), "active", 40)
    assert.are.equal(40, #header, "an over-long label must be truncated to the pane width")
    assert.are.equal(40, char_len(sep), "separator stays at the pane width regardless of label length")
  end)
end)
