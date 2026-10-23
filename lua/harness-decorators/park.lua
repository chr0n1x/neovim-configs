-- Selection and backgrounding over state.table; term.lua owns the instances.
local M = {}

local state = require("harness-decorators.state")
local term = require("harness-decorators.term")

local function entry(harness)
  return state.entry(harness)
end

---Make harness the only selected entry.
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

---Background the current harness's terminal: minimize ITS OWN float into a one-line bar if it is
---open, otherwise hide it (term.hide closes only the window), keeping the buffer/PTY alive so it
---keeps executing, and mark it unselected in the table. Never deletes the buffer - that is what makes
---resume work. A no-op if the harness has no live terminal.
---Returns true if a live terminal was actually backgrounded (so callers can report it), false otherwise.
---@param harness string
---@return boolean parked
function M.park(harness)
  if not term.is_open(harness) then
    return false
  end
  if not term.minimize(harness) then
    term.hide(harness)
  end
  entry(harness).selected = false
  return true
end

---The <leader>c entry point: show the selected harness's terminal. Finds the selected entry, ensures
---all others are unselected, then shows that harness's own float - re-showing the SAME live process if
---one exists, or spawning fresh with its command if not (term.open handles both). Returns the harness
---name shown, or nil if nothing is selected.
---@return string? shown
function M.show_selected()
  -- With nothing selected (the selection bit is dropped along with an exited harness's record), fall
  -- back to the current harness so <leader>c still opens something.
  local selected = M.selected_harness()
  if not selected then
    local ok, switch = pcall(require, "harness-decorators.switch")
    selected = ok and switch.current() or nil
  end
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
  entry(selected).selected = true
  return selected
end

---Live harnesses for the picker (see term.list).
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
