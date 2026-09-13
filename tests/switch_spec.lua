-- Spec for switch.lua (Option A, Task 6; Task 7 rework).
--
-- The core behavior: switching must BACKGROUND the outgoing harness's terminal (hide its OWN float,
-- keeping the PTY alive so it keeps executing) and record it for resume - not kill it. Under Task 7
-- the terminal layer is term.lua (one Snacks float per harness), so this spec drives it by opening a
-- fake per-harness instance via term.open (Snacks.terminal.open stubbed to return a windowless-buffer
-- fake). The assertions are the behavior change itself: after M.switch, the outgoing harness's buffer
-- is still valid AND present in the park table (not deleted), and the watcher follows the NEW active
-- harness. Headless nvim can't drive a real snacks terminal, so the fakes stand in for the floats.

local helper = require("tests.helper")
local sw = require("harness-decorators.switch")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

describe("switch: backgrounds (parks) instead of kills (Option A, Task 7)", function()
  local original_harness
  local orig_env
  local target
  local term_mod
  local snacks
  local orig_open
  local park
  local orig_notify
  local notes

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
    assert.is_not_nil(original_harness, "no active harness to switch from")
    orig_env = os.getenv("NVIM_LLM_HARNESS")

    target = nil
    for _, h in ipairs(keymaps.list_harnesses()) do
      if h ~= original_harness then
        target = h
        break
      end
    end
    assert.is_not_nil(target, "no alternate harness to switch to")

    park = require("harness-decorators.park")
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    -- Stub open so a foreground does not spawn a real terminal in headless; each call returns a fresh
    -- windowless-buffer fake (so two harnesses get two distinct buffers).
    snacks.open = function()
      return make_fake(vim.api.nvim_create_buf(false, true))
    end

    -- Capture vim.notify so we can assert on the background/foreground message.
    orig_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = tostring(msg), level = level })
    end
  end)

  teardown(function()
    if orig_notify then
      vim.notify = orig_notify
    end
    if snacks and orig_open then
      snacks.open = orig_open
    end
    require("harness-decorators.state")._reset()
    -- M.switch changed the active harness (env var + utils.harness + current_harness + keymaps).
    -- Restore all of it directly rather than calling switch again, which would spawn/kill terminals -
    -- perturbing later specs that assume the config's default harness. Re-apply the original
    -- harness's keymaps so bindings match the restored current_harness.
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    utils.harness = original_harness
    sw.init(original_harness)
    keymaps.clear()
    keymaps.apply(keymaps.build(original_harness))
  end)

  it("keeps the outgoing harness's terminal buffer alive and records it in the registry", function()
    -- The outgoing harness "has" a live float open.
    local inst = term_mod.open(original_harness)
    assert.is_not_nil(inst.buf, "open must create an instance with a buffer")

    local ok = pcall(sw.switch, target)
    assert.is_true(ok, "switch() errored")
    assert.are.equal(target, helper.active_harness(), "switch did not take effect")

    -- The core Option A assertion: the outgoing buffer was NOT deleted (old kill_terminal did).
    assert.is_true(vim.api.nvim_buf_is_valid(inst.buf),
      "switch deleted the outgoing harness's terminal buffer (Option A must keep it alive)")
    -- And it was recorded so a later re-pick can resume the same process. The backgrounded outgoing
    -- harness must be unselected.
    local entries = park.list()
    local found = false
    for _, e in ipairs(entries) do
      if e.harness == original_harness and e.buff_nr == inst.buf then
        found = true
        assert.is_false(e.selected, "backgrounded outgoing harness must not stay selected")
      end
    end
    assert.is_true(found, "outgoing harness was not recorded in the park table")

    -- The watcher follows ONLY the active harness. After switching to `target`, the watcher's active
    -- harness must be `target` (the foregrounded one), NOT the backgrounded `original_harness`.
    assert.are.equal(target, utils.harness,
      "watcher must follow the active (foregrounded) harness, not the backgrounded one")
  end)

  it("notifies 'backgrounded X, foregrounded Y' when a live terminal was parked", function()
    -- Force a known starting harness so this test is independent of prior tests' switch state.
    local start_harness = original_harness
    sw.init(start_harness)
    assert.is_not.equal(target, start_harness, "test setup: target must differ from the starting harness")

    -- The outgoing harness has a live float, so park.park backgrounds it.
    term_mod.open(start_harness)

    pcall(sw.switch, target)

    local saw_bg_fg = false
    for _, n in ipairs(notes) do
      if n.msg:find("backgrounded " .. start_harness, 1, true)
        and n.msg:find("foregrounded " .. target, 1, true) then
        saw_bg_fg = true
      end
    end
    local msgs = table.concat(vim.tbl_map(function(n) return n.msg end, notes), " | ")
    assert.is_true(saw_bg_fg, "expected a 'backgrounded X, foregrounded Y' notify; got: " .. msgs)
  end)

  it("falls back to 'switched to Y' when the outgoing harness had no live terminal", function()
    -- Force a known starting harness so this test is independent of prior tests' switch state.
    local start_harness = original_harness
    sw.init(start_harness)
    assert.is_not.equal(target, start_harness, "test setup: target must differ from the starting harness")

    -- No live terminal on the outgoing harness (never opened): park records nothing, so the notify is
    -- a plain switch, not a background/foreground claim.
    require("harness-decorators.state")._reset()

    pcall(sw.switch, target)

    local saw_plain = false
    for _, n in ipairs(notes) do
      if n.msg:find("switched to " .. target, 1, true) then
        saw_plain = true
      end
    end
    assert.is_true(saw_plain, "expected a plain 'switched to Y' notify when nothing was backgrounded")
  end)

  it("resolves the incoming harness's command from its env module at open time (Task 7)", function()
    -- The whole point of the switch under Task 7: there is no global terminal_cmd to re-point. term.lua
    -- resolves each harness's command from its env module when its float opens. So after switching to
    -- `target`, opening ITS float must spawn TARGET's command (helper.env_command reads that env.lua).
    local start_harness = original_harness
    sw.init(start_harness)

    pcall(sw.switch, target)

    -- Stub open again to capture the exact command term.open passes to Snacks for the new harness.
    local captured_cmd
    snacks.open = function(cmd)
      captured_cmd = cmd
      return make_fake(vim.api.nvim_create_buf(false, true))
    end
    require("harness-decorators.state")._reset()
    term_mod.open(target)

    assert.are.equal(helper.env_command(target), captured_cmd,
      "opening " .. target .. "'s float after a switch must use its own env command")
  end)

  it("after_pick opens the newly-selected harness's terminal (picker auto-open)", function()
    -- The picker used to only switch and leave you to press <leader>c; now selecting one should open
    -- that harness's terminal too. after_pick is the extracted callback, so drive it directly: after a
    -- switch, M.after_pick must show the selected (incoming) harness's float - spawning fresh if it has
    -- no live instance yet.
    local start_harness = original_harness
    sw.init(start_harness)
    require("harness-decorators.state")._reset()

    pcall(sw.switch, target)
    assert.is_false(term_mod.is_open(target), "precondition: incoming harness not open before after_pick")

    sw.after_pick()

    assert.is_true(term_mod.is_open(target), "after_pick must open the selected harness's terminal")
  end)
end)
