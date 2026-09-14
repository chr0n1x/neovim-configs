-- Spec for the statusline agent overview (harness-decorators.agent-display).
--
-- The overview is a SINGLE section summarizing all BACKGROUNDED (non-active) live agents as
-- "N agents" with one aggregate dot. The poll/diff/timer logic is a plain module, so this drives
-- it directly with stubbed poll maps - no live statusline, no real agent-state polling. What's
-- pinned:
--   * component() renders "<dot> N agents", empty when disabled or nothing backgrounded
--   * the active harness is EXCLUDED (it belongs to the separate session section)
--   * the aggregate dot: blue pulse if any working, green if none-working-but-known-idle,
--     hollow ring if all unknown
--   * changed() is a true shallow diff (drives "redraw only on state change")
--   * toggle() flips enabled and component() honours it

local display = require("harness-decorators.agent-display")

describe("agent-display: component rendering", function()
  setup(function()
    display._reset()
  end)

  teardown(function()
    display._reset()
    -- Clear any highlight groups the tests defined so they don't leak into other specs.
    for _, g in ipairs({
      display.HL_WORKING,
      display.HL_IDLE,
      display.HL_UNKNOWN,
      display.HL_BACKGROUND,
    }) do
      pcall(vim.api.nvim_del_hl, 0, { name = g })
    end
  end)

  it("renders empty when no harness has a live terminal", function()
    display._set_agents({})
    assert.are.equal("", display.component())
  end)

  it("excludes the active harness (it belongs to the session section)", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
    })
    display._set_active("claude") -- the only agent is the active one -> nothing backgrounded
    assert.are.equal("", display.component())
  end)

  it("renders '<gear> <dot> N agents in background' for backgrounded agents", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
      maki = { status = "idle", label = "tests", pid = 2 },
      copilot = { status = "unknown", label = nil, pid = 3 },
    })
    display._set_active("claude") -- maki + copilot are backgrounded -> N = 2
    local out = display.component()
    assert.is_not_nil(out:find("2 agents in background", 1, true), "must show the count of backgrounded agents")
    -- The dim gear marks the slot as BACKGROUND processes and sits before the status dot.
    assert.is_not_nil(out:find("%#" .. display.HL_BACKGROUND .. "#⚙ %*", 1, true), "must lead with the background-process gear")
  end)

  it("singularizes to 'agent' when exactly one is backgrounded", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
      maki = { status = "idle", label = "tests", pid = 2 },
    })
    display._set_active("claude") -- only maki is backgrounded -> N = 1
    local out = display.component()
    assert.is_not_nil(out:find("1 agent in background$", 1), "single backgrounded agent must read '1 agent' (singular)")
    assert.is_nil(out:find("1 agents", 1, true), "must not pluralize a single agent")
  end)

  it("shows a blue pulsing dot when any backgrounded agent is working", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
      maki = { status = "working", label = "tests", pid = 2 },
    })
    display._set_active("claude") -- maki is backgrounded and working
    local out = display.component()
    -- frame is 0 after _reset, so the bright phase group is used. The gear leads the status dot.
    -- The working state animates through the spinner frames (frame 0 after _reset -> first frame).
    assert.is_not_nil(out:find("%#" .. display.HL_BACKGROUND .. "#⚙ %* %#" .. display.HL_WORKING .. "#" .. display.spinner[1] .. "%*", 1, true), "working aggregate must use the blue spinner after the gear")
  end)

  it("shows a steady green dot when none are working and at least one is known-idle", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
      maki = { status = "idle", label = "tests", pid = 2 },
    })
    display._set_active("claude") -- only maki (idle) is backgrounded
    local out = display.component()
    assert.is_not_nil(out:find("%#" .. display.HL_IDLE .. "#✓%*", 1, true), "all-idle aggregate must use the green checkmark")
  end)

  it("shows a hollow ring when every backgrounded agent is in the unknown state", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
      maki = { status = "unknown", label = nil, pid = 2 },
      copilot = { status = "unknown", label = nil, pid = 3 },
    })
    display._set_active("claude") -- maki + copilot both unknown
    local out = display.component()
    assert.is_not_nil(out:find("%#" .. display.HL_UNKNOWN .. "#○%*", 1, true), "all-unknown aggregate must use the hollow ring")
  end)

  it("shows green (not blue) when a known-idle and an unknown are backgrounded but none working", function()
    display._set_agents({
      claude = { status = "working", label = "auth", pid = 1 },
      maki = { status = "idle", label = "tests", pid = 2 },
      copilot = { status = "unknown", label = nil, pid = 3 },
    })
    display._set_active("claude") -- maki idle + copilot unknown are backgrounded; none working
    local out = display.component()
    assert.is_not_nil(out:find("%#" .. display.HL_IDLE .. "#✓%*", 1, true), "known-idle present -> green checkmark")
    assert.is_nil(out:find(display.HL_WORKING, 1, true), "no working dot when no backgrounded agent is working")
  end)

  it("defines the status-dot highlight groups without clobbering an existing one", function()
    -- Seed a user-defined group so setup_highlights() must leave it alone.
    local seed_fg = 0x123456
    vim.api.nvim_set_hl(0, display.HL_WORKING, { fg = seed_fg })
    display.setup_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = display.HL_WORKING })
    assert.are.equal(seed_fg, hl.fg, "must not overwrite a user-defined working highlight")
    -- The unknown group (untouched by the seed) must now be defined.
    local unknown = vim.api.nvim_get_hl(0, { name = display.HL_UNKNOWN })
    assert.is_not_nil(unknown.fg, "unknown ring highlight must be defined")
  end)

  it("renders empty when disabled (toggled off)", function()
    display._set_agents({ maki = { status = "idle", label = "tests", pid = 2 } })
    display.toggle()
    assert.are.equal(false, display.enabled())
    assert.are.equal("", display.component(), "disabled overview must render empty")
  end)
end)

describe("agent-display: changed() shallow diff", function()
  it("reports no change for identical maps", function()
    local a = { claude = { status = "working", label = "x", pid = 1 } }
    assert.is_false(display.changed(a, vim.deepcopy(a)))
  end)

  it("reports change when a harness is added or removed", function()
    local a = { claude = { status = "idle", label = nil, pid = 1 } }
    local b = { claude = { status = "idle", label = nil, pid = 1 }, maki = { status = "idle", label = nil, pid = 2 } }
    assert.is_true(display.changed(a, b))
    assert.is_true(display.changed(b, a))
  end)

  it("reports change when status flips (the working/idle case that must redraw)", function()
    local a = { claude = { status = "working", label = "x", pid = 1 } }
    local b = { claude = { status = "idle", label = "x", pid = 1 } }
    assert.is_true(display.changed(a, b))
  end)

  it("reports change when the label or pid changes", function()
    local a = { claude = { status = "idle", label = "old", pid = 1 } }
    assert.is_true(display.changed(a, { claude = { status = "idle", label = "new", pid = 1 } }))
    assert.is_true(display.changed(a, { claude = { status = "idle", label = "old", pid = 2 } }))
  end)

  it("treats two empty maps as unchanged", function()
    assert.is_false(display.changed({}, {}))
  end)
end)

describe("agent-display: toggle()", function()
  setup(function()
    display._reset()
  end)

  teardown(function()
    display._reset()
  end)

  it("starts enabled and flips on each call", function()
    assert.is_true(display.enabled())
    assert.are.equal(false, display.toggle())
    assert.are.equal(true, display.toggle())
  end)
end)
