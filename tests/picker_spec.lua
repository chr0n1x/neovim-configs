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
