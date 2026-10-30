-- Agent overview for the statusline: one section summarizing all backgrounded (non-active) live
-- agents as "N agents" with one aggregate status dot. The active harness is shown by the separate
-- session section, so it is excluded here. Dot states:
--   * any backgrounded agent working: blue dot
--   * none working, at least one known-idle: green checkmark
--   * all unknown, or idle for IDLE_DIM_MS (shown as "stale"): dim hollow ring
-- Polling and diffing live here so tests can drive them without a live statusline.

local M = {}

local POLL_MS = 8000 -- how often we shell out to ps//proc to detect working/idle transitions
-- Static working glyph, shared with the statusline (lualine uses it for the session slot and
-- lsp_status). A single entry so nothing animates.
local SPINNER = { "●" }

M.spinner = SPINNER

-- Status glyphs: a dot while working, a checkmark (not an emoji) when idle or done, a hollow ring
-- when unknown. Shared by the statusline and the harness picker.
local GLYPH = { working = SPINNER[1], idle = "✓", unknown = "○" }
M.GLYPH = GLYPH

-- Live poll results, keyed by harness name: { [name] = {status=, label=, pid=} }.
local agents = {}
-- Whether the overview is shown at all (toggled by <leader>co). Defaults on.
local enabled = true

-- An agent idle this long shows the dim ring instead of the green checkmark.
local IDLE_DIM_MS = 120000
-- When each harness was first seen idle in its current idle stretch, keyed by harness name:
--
--   { maki = 81234567 }
--
-- A harness is absent while it is working, unknown, or gone.
local idle_since = {}
local now_ms = vim.uv.now
-- stale_key() as of the last refresh, so crossing IDLE_DIM_MS triggers a redraw.
local last_stale = ""

---The status to display for one agent: its polled status, or "stale" once idle for IDLE_DIM_MS.
---@param name string
---@param a {status: string}
---@return string
local function shown_status(name, a)
  if a.status == "idle" and idle_since[name] and now_ms() - idle_since[name] >= IDLE_DIM_MS then
    return "stale"
  end
  return a.status
end

---Comma-joined sorted names of agents currently shown as stale, for change detection.
---@return string
local function stale_key()
  local names = {}
  for name, a in pairs(agents) do
    if shown_status(name, a) == "stale" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return table.concat(names, ",")
end

-- Highlight group names for the status dots, as plain strings so tests can assert on them.
local HL_WORKING = "AgentDotWorking" -- blue
local HL_IDLE = "AgentDotIdle" -- green, all idle
local HL_UNKNOWN = "AgentDotUnknown" -- hollow ring, all unknown
local HL_BACKGROUND = "AgentDotBackground" -- dim gear marking the slot as background processes

---The active harness name (harness-decorators.active); overridable via M._set_active for tests.
local active_override
local function active_harness()
  if active_override ~= nil then
    return active_override
  end
  return require("harness-decorators.active").get()
end

---The backgrounded (non-active) live agents, as a list of {name, status}.
---@return {name: string, status: string}[]
local function backgrounded()
  local active = active_harness()
  local out = {}
  for name, a in pairs(agents) do
    if name ~= active then
      out[#out + 1] = { name = name, status = shown_status(name, a) }
    end
  end
  table.sort(out, function(x, y)
    return x.name < y.name
  end)
  return out
end

---Aggregate state of the backgrounded agents: "working" (any one working), "idle" (none working and
---at least one known-idle), or "unknown". Nil when there are no backgrounded agents.
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
  if any_idle then
    return "idle"
  end
  return "unknown"
end

---The status-dot markup for a single state: blue dot while working, green checkmark when idle, dim
---hollow ring when unknown.
---@param state string "working"|"idle"|"unknown"
---@return string
local function dot(state)
  if state == "working" then
    return "%#" .. HL_WORKING .. "#" .. GLYPH.working .. "%*"
  elseif state == "idle" then
    return "%#" .. HL_IDLE .. "#" .. GLYPH.idle .. "%*"
  end
  return "%#" .. HL_UNKNOWN .. "#" .. GLYPH.unknown .. "%*"
end

---Dot markup for the active agent; nil when unknown.
---@param status string? "working"|"idle"|"unknown"|nil
---@return string?
function M.dot_for(status)
  if status == "working" or status == "idle" then
    return dot(status)
  end
  if status == "stale" then
    return dot("unknown")
  end
  return nil
end

---Shallow diff of two poll maps. Returns true when they differ (any harness added/removed,
---or any status/label/pid changed).
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

---Store one poll result, diff it against the previous one, and schedule a statusline redraw when
---the state changed.
---@param all table<string, {status: string, label: string?, pid: number}>
---@return boolean changed
local function apply(all)
  if type(all) ~= "table" then
    return false
  end
  local did_change = M.changed(agents, all)
  local t = now_ms()
  for name in pairs(idle_since) do
    if not all[name] or all[name].status ~= "idle" then
      idle_since[name] = nil
    end
  end
  for name, a in pairs(all) do
    if a.status == "idle" and not idle_since[name] then
      idle_since[name] = t
    end
  end
  agents = all
  local stale = stale_key()
  did_change = did_change or stale ~= last_stale
  last_stale = stale
  if did_change then
    pcall(vim.schedule, function()
      vim.cmd("redrawstatus")
    end)
  end
  return did_change
end

---Run one blocking poll and apply it. Used by tests; the timer polls through refresh_async.
---@return boolean changed
function M.refresh()
  local state = require("harness-decorators.agent-state")
  local ok, all = pcall(state.all)
  return ok and apply(all) or false
end

---Poll with the ps snapshot taken off the main loop, then apply the result.
function M.refresh_async()
  local state = require("harness-decorators.agent-state")
  pcall(state.all_async, function(all)
    pcall(apply, all)
  end)
end

---The display state for one harness: its poll result, with status "stale" once it has been idle
---for IDLE_DIM_MS. Nil when the harness has no live terminal.
---@param name string
---@return {status: string, label: string?, session_id: string?, pid: number}?
function M.status(name)
  local a = agents[name]
  if not a then
    return nil
  end
  local s = shown_status(name, a)
  if s == a.status then
    return a
  end
  return vim.tbl_extend("force", a, { status = s })
end

---Number of harnesses with a live terminal as of the last poll.
---@return integer
function M.count()
  return vim.tbl_count(agents)
end

---Display string for the statusline agent-overview slot: "<dot> N agents" for the backgrounded
---agents. Empty when disabled or when there are none.
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

---Start the poll timer (idempotent). Called from lualine's opts() where the event loop is ready.
---It runs the expensive state scan every POLL_MS.
function M.start_timer()
  if not poll_timer then
    poll_timer = vim.uv.new_timer()
    if poll_timer then
      -- Poll once right away so the slot isn't empty on startup, then every POLL_MS.
      M.refresh_async()
      poll_timer:start(POLL_MS, POLL_MS, vim.schedule_wrap(M.refresh_async))
    end
  end
end

---Stop the poll timer (test teardown).
function M.stop_timer()
  poll_timer = require("harness-decorators.utils").close_timer(poll_timer)
end

---Test hook: replace the millisecond clock used for idle dimming.
---@param fn fun(): number
function M._set_now(fn)
  now_ms = fn
end

---Test hook: replace the live poll map without running agent-state.
---@param t table<string, {status:string,label:string?,pid:number}>?
function M._set_agents(t)
  agents = t or {}
end

---Test hook: reset module state (enabled on, no agents, no active override).
function M._reset()
  enabled = true
  idle_since = {}
  last_stale = ""
  now_ms = vim.uv.now
  agents = {}
  active_override = nil
end

M.POLL_MS = POLL_MS

-- Highlight group names, exported so tests (and a theme) can reference the exact groups the
-- component emits without re-deriving them.
M.HL_WORKING = HL_WORKING
M.HL_IDLE = HL_IDLE
M.HL_UNKNOWN = HL_UNKNOWN
M.HL_BACKGROUND = HL_BACKGROUND

---Test hook: override which harness is treated as active (nil = the active module). Lets specs pin
---which agents are backgrounded without driving real park selection state.
---@param name string?
function M._set_active(name)
  active_override = name
end

---Define the status-dot highlight groups, only where still undefined (fg nil) so a theme's own
---definition wins.
function M.setup_highlights()
  local function define(group, spec)
    -- fg is nil only for a group that has never been defined, so it doubles as the "not set yet"
    -- probe (bg cannot be used: these groups carry no bg).
    if vim.api.nvim_get_hl(0, { name = group }).fg == nil then
      vim.api.nvim_set_hl(0, group, spec)
    end
  end
  define(HL_WORKING, { fg = "#3d9bff", bold = true }) -- vibrant blue
  define(HL_IDLE, { fg = "#3ddc6e" }) -- vibrant green
  define(HL_UNKNOWN, { fg = "#5b6270" }) -- dim hollow ring
  define(HL_BACKGROUND, { fg = "#5b6270" }) -- dim gear (background-process marker)
end

return M
