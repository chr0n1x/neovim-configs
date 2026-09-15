-- Selection + backgrounding layer over the unified per-harness terminal state (Task 6; Task 7 rework;
-- Task 8 consolidated the storage).
--
-- Every annotation about a harness - its live Snacks instance AND its selection bit - lives on ONE
-- record in the shared state table (harness-decorators/state.lua):
--
--   state.table[harness] = { inst = snacks.terminal|nil, selected = boolean }
--
-- This module owns the SELECTION half of that record (set_selected / selected_harness) and
-- backgrounding (park). term.lua owns opening/hiding/showing the instance on the same record. There
-- is no private registry here anymore: the old `registry[harness].inst` duplicated term's instance,
-- which had to be written back on every open - that duplication is gone. Backgrounding a harness
-- hides ITS OWN float (term.hide) - the PTY keeps running, which is the concurrency requirement.
-- Re-selecting re-shows the SAME live process because we hide (not close) the buffer. There is no
-- claudecode handle to attach/detach: term.lua owns each instance, so "maki shows claude" cannot
-- happen - a harness can only ever show its own buffer. See docs/multi-agent-prd.md.
local M = {}

local state = require("harness-decorators.state")
local term = require("harness-decorators.term")

---The shared per-harness record for `harness`, creating it if absent (inst=nil, selected=false).
-- Delegates to the single accessor in state.lua so term and park never diverge on the record shape.
---@param harness string
---@return table entry { inst = snacks.terminal|nil, selected = boolean }
local function entry(harness)
  return state.entry(harness)
end

---Mark `harness` as the selected (foreground-target) harness: set its entry selected=true and every
---other entry selected=false. Creates the entry if absent (inst=nil, so its first <leader>c spawns it
---fresh). Called by switch after deciding the incoming harness is now active. Routes through the
---single invariant-enforcing accessor in state.lua.
---@param harness string
function M.set_selected(harness)
  state.select(harness)
end

---The currently-selected harness name, or nil.
---@return string?
function M.selected_harness()
  for name, e in pairs(state.table) do
    if e.selected then
      return name
    end
  end
  return nil
end

---Background the current harness's terminal: hide ITS OWN float (term.hide closes only the window,
---keeping the buffer/PTY alive so it keeps executing) and mark it unselected in the table. Never
---deletes the buffer - that is what makes resume work. A no-op if the harness has no live terminal.
---Returns true if a live terminal was actually backgrounded (so callers can report it), false otherwise.
---@param harness string
---@return boolean parked
function M.park(harness)
  if not term.is_open(harness) then
    return false
  end
  term.hide(harness)
  entry(harness).selected = false
  return true
end

---The <leader>c entry point: show the selected harness's terminal. Finds the selected entry, ensures
---all others are unselected, then shows that harness's own float - re-showing the SAME live process if
---one exists, or spawning fresh with its command if not (term.open handles both). Returns the harness
---name shown, or nil if nothing is selected.
---@return string? shown
function M.show_selected()
  local selected = M.selected_harness()
  if not selected then
    return nil
  end
  -- Enforce the invariant (exactly one selected) before showing, guarding against any path that left
  -- two true. state.select clears all others and re-sets this one atomically.
  state.select(selected)

  local inst = term.open(selected)
  if not inst then
    return nil
  end
  -- term.open already recorded the instance on the shared record; just make sure the selection bit
  -- is set (it should be, but a path that called open without selecting would leave it false).
  entry(selected).selected = true
  return selected
end

---Table snapshot for the picker previewer: a list of { harness, buff_nr, selected, cmd } for every
---harness with a live terminal. Stale entries (dead buffers) are dropped so the picker never offers a
---harness whose process already exited. Never-opened harnesses (no instance) are omitted - they have
---no output to preview yet. Backed entirely by term.list() (the per-harness Snacks instances).
---@return { harness: string, buff_nr: number, selected: boolean, cmd: string? }[]
function M.list()
  local out = {}
  for _, e in ipairs(term.list()) do
    local rec = state.table[e.harness] or {}
    table.insert(out, {
      harness = e.harness,
      buff_nr = e.bufnr,
      selected = rec.selected == true,
      cmd = nil, -- command is resolved from env at open time; not stored per-entry
    })
  end
  table.sort(out, function(a, b)
    return a.harness < b.harness
  end)
  return out
end

---Test-only: the full table as a list of { harness, selected }, INCLUDING never-opened entries
---(inst=nil) that M.list omits. Lets specs assert on selection state without a live buffer.
---@return { harness: string, selected: boolean }[]
function M._all_for_test()
  local out = {}
  for harness, e in pairs(state.table) do
    table.insert(out, { harness = harness, selected = e.selected == true })
  end
  table.sort(out, function(a, b)
    return a.harness < b.harness
  end)
  return out
end

---Test-only: clear the shared state table without touching any buffer.
function M._reset()
  state._reset()
end

return M
