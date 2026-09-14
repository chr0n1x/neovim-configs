-- Agent overview for the statusline: a SINGLE section summarizing all BACKGROUNDED (non-active)
-- live agents as "N agents" with one aggregate status dot. The active harness is shown by the
-- separate session section, so it is excluded here. Dot semantics:
--   * any backgrounded agent working -> blue, pulsing
--   * none working, at least one known-idle -> green, steady
--   * all in the unknown state -> dim hollow ring
-- The polling + diff lives here (not in lualine) so it is a plain module function that tests can
-- drive without a live statusline - same shape as session_component.

local M = {}

local POLL_MS = 2000 -- how often we shell out to ps//proc to detect working/idle transitions
local SPIN_MS = 100 -- how fast the spinner advances a frame while an agent is working. Kept separate
-- from POLL_MS so the spin stays smooth without re-running the expensive state poll every frame.
-- The spinner frames, shared with the statusline (lualine requires this table). The WORKING dot
-- animates through these instead of pulsing a solid dot - a spinning glyph reads as "actively doing
-- work" while idle/unknown stay static. Kept here (not in lualine) so both consumers share one list.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

M.spinner = SPINNER

-- Live poll results, keyed by harness name: { [name] = {status=, label=, pid=} }.
local agents = {}
-- Monotonic spinner frame index (0-based), advanced only while a backgrounded agent is working.
local frame = 0
-- Whether the overview is shown at all (toggled by <leader>ca). Defaults on.
local enabled = true

-- Highlight group names for the summary status dot. The overview is now a SINGLE section that
-- summarizes all BACKGROUNDED (non-active) live agents as "N agents" with one aggregate dot:
--   * any backgrounded agent working  -> blue, pulsing (bright/dim phase)
--   * none working, all known-idle    -> green, steady
--   * all in the unknown state        -> hollow ring, dim
-- Defined as plain strings so tests can assert on them without a live theme.
local HL_WORKING = "AgentDotWorking" -- blue, bright phase
-- NOTE: the pulse's dim phase is NOT a separate highlight group. It reuses AgentDotUnknown (the
-- hollow-ring color #5b6270), so the lit and dimmed dot share one fg color and stay y-axis aligned
-- in terminals that shift glyph baselines per color/weight. A dedicated dim-blue group made the
-- bright/dim frames render at slightly different vertical positions.
local HL_IDLE = "AgentDotIdle" -- green, all idle
local HL_UNKNOWN = "AgentDotUnknown" -- hollow ring, all unknown
local HL_BACKGROUND = "AgentDotBackground" -- dim gear marking the slot as background processes

---The currently-active harness name, or nil. Resolved lazily from park so the display module does
--not hard-depend on it at load time (avoids a require cycle); overridable via M._set_active for tests.
local active_override
local function active_harness()
  if active_override ~= nil then
    return active_override
  end
  local ok, park = pcall(require, "harness-decorators.park")
  if not ok then
    return nil
  end
  return park.selected_harness()
end

---The backgrounded (non-active) live agents, as a list of {name, status}. The active harness is the
--one shown by the separate session section, so the overview only summarizes the rest.
---@return {name: string, status: string}[]
local function backgrounded()
  local active = active_harness()
  local out = {}
  for name, a in pairs(agents) do
    if name ~= active then
      out[#out + 1] = { name = name, status = a.status }
    end
  end
  table.sort(out, function(x, y)
    return x.name < y.name
  end)
  return out
end

---Aggregate state of the backgrounded agents: "working" (any one working), "idle" (none working and
--at least one known-idle, i.e. not all unknown), or "unknown" (all in the unknown state). Returns
--nil when there are no backgrounded agents at all.
---@return string? "working"|"idle"|"unknown"
local function aggregate_state()
  local list = backgrounded()
  if #list == 0 then
    return nil
  end
  local any_working, any_idle = false, false
  for _, a in ipairs(list) do
    if a.status == "working" then
      any_working = true
    elseif a.status == "idle" then
      any_idle = true
    end
  end
  if any_working then
    return "working"
  end
  -- None working: green only when we actually KNOW they're idle (at least one known-idle). If every
  -- backgrounded agent is in the unknown state, show the hollow ring instead.
  if any_idle then
    return "idle"
  end
  return "unknown"
end

---The summary dot for the aggregate state: blue and pulsing while working, steady green when idle,
--a dim hollow ring when unknown.
---@param state string "working"|"idle"|"unknown"
---@return string
local function dot(state)
  if state == "working" then
    -- The working state animates through the spinner frames (see SPINNER), colored blue. The frame
    -- index advances every poll while a backgrounded agent is working, so this spins continuously.
    return "%#" .. HL_WORKING .. "#" .. SPINNER[frame % #SPINNER + 1] .. "%*"
  elseif state == "idle" then
    -- Idle/done reads as a checkmark (not an emoji) - the agent finished and is waiting.
    return "%#" .. HL_IDLE .. "#✓%*"
  end
  return "%#" .. HL_UNKNOWN .. "#○%*"
end

---The status-dot markup for a single KNOWN state, or nil when the state is unknown/nil. The session
--component uses this to show the ACTIVE agent's own dot next to its session id - only when we know
--its state (working/idle), never a hollow "unknown" ring there (that would just be noise for the
--agent you're actively looking at).
---@param status string? "working"|"idle"|"unknown"|nil
---@return string?
function M.dot_for(status)
  if status == "working" then
    -- The active agent's own working state also animates through the spinner frames, colored blue.
    return "%#" .. HL_WORKING .. "#" .. SPINNER[frame % #SPINNER + 1] .. "%*"
  elseif status == "idle" then
    -- Idle/done reads as a checkmark (not an emoji) - the agent finished and is waiting.
    return "%#" .. HL_IDLE .. "#✓%*"
  end
  return nil
end

---True when any BACKGROUNDED agent is working (drives whether the pulse advances). The active
--harness's own status is handled by the separate session section, so it does not drive this pulse.
---@return boolean
local function any_backgrounded_working()
  return aggregate_state() == "working"
end

---Shallow diff of two poll maps. Returns true when they differ (any harness added/removed,
--or any status/label/pid changed).
---@param a table<string, {status:string,label:string?,pid:number}>
---@param b table<string, {status:string,label:string?,pid:number}>
---@return boolean
function M.changed(a, b)
  if vim.tbl_isempty(a) ~= vim.tbl_isempty(b) then
    return true
  end
  for k, va in pairs(a) do
    local vb = b[k]
    if not vb or va.status ~= vb.status or va.label ~= vb.label or va.pid ~= vb.pid then
      return true
    end
  end
  for k in pairs(b) do
    if not a[k] then
      return true
    end
  end
  return false
end

---Run one poll (the expensive ps//proc scan), diff against the previous result, and schedule a
--statusline redraw when the state changed. The spinner frame is NOT advanced here - that's the job
--of the fast spin timer (see start_timer) so the animation stays smooth without re-polling every
--frame. Also safe to call directly in tests.
---@return boolean changed
function M.refresh()
  local ok, all = pcall(function()
    return require("harness-decorators.agent-state").all()
  end)
  if not ok or type(all) ~= "table" then
    return false
  end
  local did_change = M.changed(agents, all)
  agents = all
  if did_change then
    pcall(vim.schedule, function()
      vim.cmd("redrawstatus")
    end)
  end
  return did_change
end

---Advance the spinner one frame and redraw. Driven by the fast spin timer, but only does real work
--while a backgrounded agent is working - a steady idle/unknown section must not flicker.
function M.tick()
  if any_backgrounded_working() then
    frame = (frame + 1) % #SPINNER
    pcall(vim.schedule, function()
      vim.cmd("redrawstatus")
    end)
  end
end

---Display string for the statusline agent-overview slot. A SINGLE section summarizing all
--BACKGROUNDED (non-active) live agents: "<dot> N agents". The active harness is shown by the
--separate session section, so it is excluded here. Empty when disabled or when there are no
--backgrounded agents.
---@return string
function M.component()
  if not enabled then
    return ""
  end
  local list = backgrounded()
  if #list == 0 then
    return ""
  end
  local state = aggregate_state()
  local n = #list
  local noun = n == 1 and "agent" or "agents"
  -- The dim gear marks this slot as BACKGROUND processes (the active agent lives in the session
  -- section), so the status dot that follows reads as "these background agents are <state>". Two
  -- spaces after the gear: one would leave it visually glued to the round dot.
  return "%#AgentDotBackground#⚙ %* " .. dot(state) .. " " .. n .. " " .. noun .. " in background"
end

---Toggle the overview on/off. Returns the new enabled state.
---@return boolean
function M.toggle()
  enabled = not enabled
  pcall(vim.schedule, function()
    vim.cmd("redrawstatus")
  end)
  return enabled
end

---Whether the overview is currently shown.
---@return boolean
function M.enabled()
  return enabled
end

local poll_timer
local spin_timer

---Start the poll + spin timers (idempotent). Called from lualine's opts() where the event loop is
--ready. The poll timer runs the expensive state scan every POLL_MS; the spin timer advances the
--spinner frame every SPIN_MS while an agent is working (no-op otherwise), so the animation is
--smooth without re-polling on every frame.
function M.start_timer()
  if not poll_timer then
    poll_timer = vim.uv.new_timer()
    if poll_timer then
      -- Run once immediately so the slot isn't empty on startup, then every POLL_MS.
      M.refresh()
      poll_timer:start(
        POLL_MS,
        POLL_MS,
        vim.schedule_wrap(function()
          M.refresh()
        end)
      )
    end
  end
  if not spin_timer then
    spin_timer = vim.uv.new_timer()
    if spin_timer then
      spin_timer:start(
        SPIN_MS,
        SPIN_MS,
        vim.schedule_wrap(function()
          M.tick()
        end)
      )
    end
  end
end

---Stop both timers (test teardown).
function M.stop_timer()
  if poll_timer then
    pcall(poll_timer.stop)
    pcall(poll_timer.close)
    poll_timer = nil
  end
  if spin_timer then
    pcall(spin_timer.stop)
    pcall(spin_timer.close)
    spin_timer = nil
  end
end

---Test hook: replace the live poll map without running agent-state.
---@param t table<string, {status:string,label:string?,pid:number}>?
function M._set_agents(t)
  agents = t or {}
end

---Test hook: reset module state (enabled on, frame 0, no agents, no active override).
function M._reset()
  enabled = true
  frame = 0
  agents = {}
  active_override = nil
end

M.POLL_MS = POLL_MS
M.SPIN_MS = SPIN_MS

-- Highlight group names, exported so tests (and a theme) can reference the exact groups the
-- component emits without re-deriving them.
M.HL_WORKING = HL_WORKING
M.HL_IDLE = HL_IDLE
M.HL_UNKNOWN = HL_UNKNOWN
M.HL_BACKGROUND = HL_BACKGROUND

---Test hook: override which harness is treated as active (nil = resolve from park). Lets specs pin
--which agents are backgrounded without driving real park selection state.
---@param name string?
function M._set_active(name)
  active_override = name
end

---Define the summary status-dot highlight groups. Idempotent: we only create a group when it is
--still undefined (fg nil) so a user/theme that already set one is never clobbered. The working dot
--is blue with a bright/dim pulse; idle is steady green; unknown is a dim hollow ring.
function M.setup_highlights()
  local function define(group, spec)
    -- fg is nil only for a group that has never been defined, so it doubles as the "not set yet"
    -- probe (bg cannot be used: these groups carry no bg).
    if vim.api.nvim_get_hl(0, { name = group }).fg == nil then
      vim.api.nvim_set_hl(0, group, spec)
    end
  end
  define(HL_WORKING, { fg = "#3d9bff", bold = true }) -- vibrant blue phase
  define(HL_IDLE, { fg = "#3ddc6e" }) -- vibrant green
  define(HL_UNKNOWN, { fg = "#5b6270" }) -- dim hollow ring
  define(HL_BACKGROUND, { fg = "#5b6270" }) -- dim gear (background-process marker)
end

return M
