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
    local display = require("harness-decorators.agent-display")
    local out = decorators.session_component("⠋")
    -- Only the robot emoji carries the section fill; the waiting spinner uses the working-state blue.
    assert.are.equal("%#lualine_x_normal#🤖%* %#" .. display.HL_WORKING .. "#⠋%*", out, "no-pin claude should show the blue spinner frame")
  end)

  it("shows the pinned session slug (claude stem)", function()
    utils.harness = "claude"
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/deadbeef.jsonl"
    assert.are.equal("%#lualine_x_normal#🤖%* deadbeef", decorators.session_component("⠋"))
  end)

  it("shows the harness-aware slug (copilot parent dir, not the events.jsonl stem)", function()
    -- The raw path:match("([^/]+)%.jsonl$") would yield "events" here; the correct id is the
    -- parent dir. This is the bug the refactor fixes.
    utils.harness = "copilot"
    watcher.pinned_jsonl_path = "/home/u/.copilot/sess-42/events.jsonl"
    assert.are.equal("%#lualine_x_normal#🤖%* sess-42", decorators.session_component("⠋"))
  end)

  it("shows the active stub harness and its status instead of hiding the slot", function()
    local display = require("harness-decorators.agent-display")
    for _, h in ipairs({ "crush", "pi" }) do
      display._set_agents({
        [h] = {
          status = h == "crush" and "working" or "idle",
          label = nil,
          pid = 1,
          session_id = h == "crush" and "d5bb8c50-400e" or nil,
        },
      })
      utils.harness = h
      watcher.pinned_jsonl_path = nil
      local out = decorators.session_component("⠋")
      local expected = h == "crush" and display.HL_WORKING or display.HL_IDLE
      local identity = h == "crush" and "d5bb8c50-400e" or h
      assert.is_not_nil(out:find("%#" .. expected .. "#", 1, true), h .. ": active status light must be visible")
      assert.is_not_nil(out:find(identity, 1, true), h .. ": active session identity must be visible")
    end
  end)

  it("appends the active agent's own status dot when its state is known", function()
    -- The session component reads the cached poll result so fast spinner redraws never run ps/SQLite.
    local display = require("harness-decorators.agent-display")
    utils.harness = "claude"
    watcher.pinned_jsonl_path = "/home/u/.claude/projects/x/deadbeef.jsonl"

    display._set_agents({ claude = { status = "working", label = nil, pid = 1 } })
    local working = decorators.session_component("⠋")
    -- The working state animates through the spinner frames (frame 0 -> first frame). It sits right
    -- after the emoji and before the session id; only the emoji carries the section fill.
    assert.is_not_nil(working:find("%#lualine_x_normal#🤖%* %#" .. display.HL_WORKING .. "#" .. display.spinner[1] .. "%* deadbeef", 1, true), "known-working active agent must show the blue spinner after the emoji")

    display._set_agents({ claude = { status = "idle", label = nil, pid = 1 } })
    local idle = decorators.session_component("⠋")
    assert.is_not_nil(idle:find("%#lualine_x_normal#🤖%* %#" .. display.HL_IDLE .. "#✓%* deadbeef", 1, true), "known-idle active agent must show the green checkmark after the emoji")

    display._set_agents({ claude = { status = "unknown", label = nil, pid = 1 } })
    local unknown = decorators.session_component("⠋")
    assert.are.equal("%#lualine_x_normal#🤖%* deadbeef", unknown, "unknown active-agent state must show NO dot (no hollow ring of noise)")
  end)
end)
