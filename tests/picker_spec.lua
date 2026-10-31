-- Spec for the <leader>cl picker's preview data path.
--
-- The picker itself is telescope UI and can't be driven headless, but its preview pane is fed by
-- switch.collect_terminal_bufs(): a map from harness name to terminal buffer, built entirely from
-- the shared state table that term.lua fills (one Snacks float per harness). That map is what lets
-- the preview show "what each harness is doing". This spec drives it directly: it opens fake per-
-- harness instances via term.open (Snacks.terminal.open stubbed to return windowless-buffer fakes),
-- so no real PTY or window is created in headless.
local helper = require("tests.helper")
local sw = require("harness-decorators.switch")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

describe("picker: collect_terminal_bufs maps harnesses to live buffers", function()
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
    require("harness-decorators.active").set(original_harness)
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
    for _, h in ipairs(utils.list_harnesses()) do
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

-- The picker entry is a plain table (optional work-status dot + colored name), built by
-- switch.make_entry. It can be driven headless: no telescope UI, just the display() closure that
-- returns the text and highlight ranges. This spec asserts that an initialized harness (live buffer)
-- shows a leading work-status dot in its agent-display group before the name, that a never-opened
-- harness shows no dot, and that the name is always colored with its HarnessTitle<Name> group (the
-- dot and the name are highlighted independently).
describe("picker: make_entry renders a work-status dot + harness name", function()
  local display
  local state
  local orig_poll

  setup(function()
    -- The status dot reads the statusline's cached poll (agent-display), so the specs seed that
    -- cache. agent-state.poll is stubbed to fail: building a row must never poll.
    display = require("harness-decorators.agent-display")
    state = require("harness-decorators.agent-state")
    orig_poll = state.poll
    state.poll = function()
      error("make_entry must not poll agent-state")
    end
  end)

  teardown(function()
    state.poll = orig_poll
    display._reset()
  end)

  ---Seed the cached status for every harness the specs use.
  local function cached_status(status)
    local agents = {}
    for _, n in ipairs({ "claude", "maki", "pi" }) do
      agents[n] = { status = status, pid = 1 }
    end
    display._set_agents(agents)
  end

  ---Collect the highlight ranges display() returns, keyed by group name.
  local function groups_of(name, bufs)
    local entry = sw.make_entry(name, bufs)
    local _, ranges = entry.display()
    local out = {}
    for _, r in ipairs(ranges or {}) do
      out[r[2]] = { start = r[1][1], stop = r[1][2] }
    end
    return out
  end

  it("shows a blue work-status dot before the name of a working initialized harness", function()
    cached_status("working")
    local g = groups_of("claude", { claude = 42 })
    assert.is_not_nil(g[display.HL_WORKING], "working dot group missing")
    -- The dot is "● " (a 4-byte UTF-8 circle + space); the name starts right after it.
    assert.are.equal(0, g[display.HL_WORKING].start)
    assert.are.equal(#"● ", g[display.HL_WORKING].stop)
    assert.is_not_nil(g.HarnessTitleClaude, "name must still be colored")
  end)

  it("shows a green dot before the name of an idle initialized harness", function()
    cached_status("idle")
    local g = groups_of("maki", { maki = 42 })
    assert.is_not_nil(g[display.HL_IDLE], "idle dot group missing")
    assert.are.equal(0, g[display.HL_IDLE].start)
    assert.is_not_nil(g.HarnessTitleMaki, "name must still be colored")
  end)

  it("shows a hollow ring before the name of an unknown initialized harness", function()
    cached_status("unknown")
    local g = groups_of("maki", { maki = 42 })
    assert.is_not_nil(g[display.HL_UNKNOWN], "unknown dot group missing")
    -- The unknown glyph is a hollow ring "○ ".
    assert.are.equal(#"○ ", g[display.HL_UNKNOWN].stop)
  end)

  it("shows no dot for a harness that was never opened (no live buffer)", function()
    cached_status("working")
    local g = groups_of("pi", {})
    assert.is_nil(g[display.HL_WORKING], "never-opened harness must not show a working dot")
    assert.is_nil(g[display.HL_IDLE], "never-opened harness must not show an idle dot")
    -- Only the name is highlighted (no dot group).
    assert.is_not_nil(g.HarnessTitlePi, "name must still be colored")
  end)

  it("highlights the name starting right after the dot", function()
    cached_status("working")
    local g = groups_of("claude", { claude = 42 })
    -- The working dot is "● " (4 bytes); 'claude' is 6 bytes, so the name spans [4, 10).
    assert.are.equal(#"● ", g.HarnessTitleClaude.start, "name should start right after the dot")
    assert.are.equal(#"● " + #"claude", g.HarnessTitleClaude.stop)
  end)

  it("falls back to plain text when the harness has no title group", function()
    -- An unknown harness name has no HarnessTitle<Name> group; display must not error and returns
    -- just the text (no highlight ranges).
    local entry = sw.make_entry("unknown", {})
    local text, ranges = entry.display()
    assert.is_string(text)
    assert.is_nil(ranges)
  end)

  it("renders an uninstalled harness with a dimmed suffix and no dot", function()
    cached_status("working")
    local entry = sw.make_entry("claude", { claude = 42 }, false)
    local text, ranges = entry.display()
    assert.is_not_nil(text:find("(not installed)"), "display must include the not-installed suffix")
    -- The suffix range uses the HarnessPickerNotInstalled group.
    local found_suffix = false
    for _, r in ipairs(ranges or {}) do
      if r[2] == "HarnessPickerNotInstalled" then
        found_suffix = true
        break
      end
    end
    assert.is_true(found_suffix, "suffix must be highlighted with HarnessPickerNotInstalled")
    -- An uninstalled harness shows no work-status dot even if it has a buffer.
    assert.is_nil(text:find("●"), "uninstalled row must not show a status dot")
  end)

  it("installed harnesses show no suffix when installed arg is omitted", function()
    cached_status("idle")
    local entry = sw.make_entry("claude", { claude = 42 })
    local text = entry.display()
    assert.is_nil(text:find("(not installed)"), "installed row must not show the suffix")
  end)
end)

-- The picker's static config (layout strategy + the three titles) is not observable without opening
-- telescope UI, so this spec stubs telescope.pickers to capture the opts M.pick() passes and asserts
-- on them. This keeps the layout/titles contract tested headless.
describe("picker: M.pick uses a horizontal layout with the expected titles", function()
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
    -- Restore the real telescope module. M.pick() only reads config, so the shared state table is
    -- left as the specs before it set it up.
    package.loaded["telescope.pickers"] = nil
  end)

  it(
    "Given cached agent statuses, When rows are ordered, Then the active harness leads, idle ones follow, and nothing polls",
    function()
      local state = require("harness-decorators.agent-state")
      local display = require("harness-decorators.agent-display")
      local original_poll = state.poll
      local active = sw.current()
      -- The idle harness sorts after the other one by name, so only its idle status can lift it.
      local idle = active == "pi" and "crush" or "pi"
      local other = active == "maki" and "copilot" or "maki"
      state.poll = function()
        error("order_harnesses must not poll agent-state")
      end
      display._set_agents({ [idle] = { status = "idle", pid = 1 } })

      local ok, ordered = pcall(sw.order_harnesses, {
        { name = other, installed = true },
        { name = idle, installed = true },
        { name = active, installed = true },
      })
      state.poll = original_poll
      display._reset()
      assert(ok, ordered)

      assert.are.equal(active, ordered[1].name)
      assert.are.equal(idle, ordered[2].name)
    end
  )

  it("uses the horizontal layout strategy with the prompt on the bottom", function()
    sw.pick()
    assert.is_not_nil(captured, "M.pick did not reach telescope.pickers.new")
    assert.are.equal("horizontal", captured.layout_strategy)
    assert.are.equal("bottom", captured.layout_config.prompt_position)
  end)

  it("Given the <C-q> picker, Then it takes 40% of the editor width (half the old 80%)", function()
    sw.pick()
    assert.are.equal(0.4, captured.layout_config.width)
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

  it("selects the current active harness by default", function()
    sw.pick()
    local expected
    for index, h in ipairs(require("harness-decorators.agent-state").harnesses()) do
      if h.name == sw.current() then
        expected = index
        break
      end
    end
    assert.is_not_nil(expected, "current harness must be present in the picker results")
    assert.are.equal(expected, captured.default_selection_index)
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

describe("picker: zen mode across a <C-q> pick", function()
  local zen_view, zen, real_is_open, real_open, opened_in, file_win, float_win

  before_each(function()
    package.loaded["telescope.pickers"] = {
      new = function()
        return { find = function() end }
      end,
    }
    zen_view = require("zen-mode.view")
    zen = require("zen-mode")
    real_is_open, real_open = zen_view.is_open, zen.open
    opened_in = nil
    zen.open = function()
      opened_in = vim.api.nvim_get_current_win()
    end
    file_win = vim.api.nvim_get_current_win()
    float_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "editor",
      width = 10,
      height = 5,
      row = 1,
      col = 1,
    })
  end)

  after_each(function()
    zen_view.is_open, zen.open = real_is_open, real_open
    zen_view.parent = nil
    package.loaded["telescope.pickers"] = nil
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
    pcall(vim.api.nvim_set_current_win, file_win)
  end)

  it("Given zen mode is closed, When a pick completes, Then zen mode stays closed", function()
    zen_view.is_open = function()
      return false
    end
    sw.pick()
    sw.after_pick()
    vim.cmd("stopinsert")
    vim.wait(500, function()
      return opened_in ~= nil
    end)
    assert.is_nil(opened_in, "zen must not open after a pick when it was closed before")
  end)

  it(
    "Given zen mode is open around a file window, When a pick completes with focus in a harness float, Then zen reopens around that file window",
    function()
      zen_view.is_open = function()
        return true
      end
      sw.pick()
      zen_view.is_open = function()
        return false
      end
      zen_view.parent = file_win
      sw.after_pick()
      if vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_set_current_win(float_win)
      end
      vim.cmd("stopinsert")
      vim.wait(500, function()
        return opened_in ~= nil
      end)
      assert.are.equal(file_win, opened_in, "zen must wrap the file window, not the harness float")
    end
  )
end)
