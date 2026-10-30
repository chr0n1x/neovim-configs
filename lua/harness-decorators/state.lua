-- Per-harness terminal state shared by term.lua and park.lua.
--
--   table[harness] = { inst = snacks.terminal|nil, selected = boolean }
--
-- At most one entry is selected; inst is nil until first opened. term owns .inst, park owns .selected.
local M = {}

---Per-harness records keyed by harness name.
M.table = {}

---The record for `harness`, created if absent (inst=nil, selected=false).
---@param harness string
---@return table entry { inst = snacks.terminal|nil, selected = boolean }
function M.entry(harness)
  local e = M.table[harness]
  if not e then
    e = { inst = nil, selected = false }
    M.table[harness] = e
  end
  return e
end

---Make `harness` the only selected entry, creating it if absent.
---@param harness string
function M.select(harness)
  for _, e in pairs(M.table) do
    e.selected = false
  end
  M.entry(harness).selected = true
end

---The harness whose record holds `inst`, or nil.
---@param inst table?
---@return string?
function M.harness_of(inst)
  if inst == nil then
    return nil
  end
  for harness, e in pairs(M.table) do
    if e.inst == inst then
      return harness
    end
  end
  return nil
end

---Test-only: clear the whole table without touching any buffer (buffers are managed by Snacks).
function M._reset()
  M.table = {}
end

return M
