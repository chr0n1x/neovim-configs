-- Specs for the lualine harness/session component (harness-decorators.session_component).
-- This is the statusline slot that shows either a spinner (no pin yet) or the pinned session
-- slug. Two bugs it guards: (1) the slug must be harness-aware (copilot's id is the parent
-- dir, not the filename stem), and (2) a stub harness with no sessions dir must not spin
-- forever - it can never pin, so the spinner is just noise.

-- The display logic lives in harness-decorators.session_component (a plain module function),
-- not in plugins/lualine.lua, so this spec drives it without a live statusline.
local decorators = require("harness-decorators")
local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")

describe("lualine session component", function()
  local orig_pin, orig_harness

  setup(function()
    orig_pin = watcher.pinned_jsonl_path
    orig_harness = utils.harness
  end)

  teardown(function()
    watcher.pinned_jsonl_path = orig_pin
    utils.harness = orig_harness
  end)

  it("shows a spinner when there is no pin and the harness can pin (claude)", function()
    utils.harness = "claude"
    watcher.pinned_jsonl_path = nil
    local out = decorators.session_component("⠋")
    assert.are.equal("🤖 ⠋", out, "no-pin claude should show the spinner frame")
  end)

  it("shows the pinned session slug (claude stem)", function()
    utils.harness = "claude"
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/deadbeef.jsonl"
    assert.are.equal("🤖 deadbeef", decorators.session_component("⠋"))
  end)

  it("shows the harness-aware slug (copilot parent dir, not the events.jsonl stem)", function()
    -- The raw path:match("([^/]+)%.jsonl$") would yield "events" here; the correct id is the
    -- parent dir. This is the bug the refactor fixes.
    utils.harness = "copilot"
    watcher.pinned_jsonl_path = "/home/u/.copilot/sess-42/events.jsonl"
    assert.are.equal("🤖 sess-42", decorators.session_component("⠋"))
  end)

  it("shows nothing (no spinner) for a stub harness with no sessions dir", function()
    -- crush and pi have projects_dir() == nil, so they can never pin. A perpetual spinner is
    -- noise; the component should render empty instead.
    for _, h in ipairs({ "crush", "pi" }) do
      utils.harness = h
      watcher.pinned_jsonl_path = nil
      local out = decorators.session_component("⠋")
      assert.are.equal("", out, ("%s: stub harness must not spin forever"):format(h))
    end
  end)
end)
