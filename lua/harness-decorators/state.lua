-- Unified per-harness terminal state (Task 8).
--
-- The Snacks.terminal instance IS the state: every annotation we keep about a harness - which one is
-- selected, whether it has a live float - lives on the same record as the instance itself, so there
-- is exactly ONE table to look at and nothing to keep in sync across modules. This replaces the old
-- split where term.lua kept `instances[harness]` (the Snacks handles) and park.lua kept a parallel
-- registry with a DUPLICATED `.inst` field that had to be written back on every open (the smell).
--
--   table[harness] = { inst = snacks.terminal|nil, selected = boolean }
--
--   * selected == true  -> the harness <leader>c should show (at most one at a time)
--   * inst              -> that harness's live Snacks instance (nil until first opened)
--
-- term.lua and park.lua are now thin layers over this table: term owns open/hide/show/bufnr routing
-- to the per-harness instances, park owns selection + backgrounding. Neither keeps its own copy of
-- the other's data - both read/write through here. See docs/multi-agent-prd.md (Task 8).
local M = {}

---harness name -> { inst = snacks.terminal|nil, selected = boolean }. The single source of truth for
-- "which harness terminal is live and which is selected". term.open records the instance it spawned;
-- park.set_selected flips the selection bit. No other module stores a copy of either field.
M.table = {}

---The shared per-harness record for `harness`, creating it if absent (inst=nil, selected=false). The
-- single create-if-absent accessor: term.lua and park.lua both route every instance/selection read or
-- write through here so they can never diverge on the record's shape.
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

---Make `harness` the single selected entry: clear every other entry's selection bit and set this one.
-- This is the ONE place the "at most one selected" invariant is written, so park.set_selected and
-- park.show_selected both route through it instead of each re-implementing the clear-all-then-set.
---Creates the entry if absent (inst=nil, so its first <leader>c spawns fresh).
---@param harness string
function M.select(harness)
  for _, e in pairs(M.table) do
    e.selected = false
  end
  M.entry(harness).selected = true
end

---Test-only: clear the whole table without touching any buffer (buffers are managed by Snacks).
function M._reset()
  M.table = {}
end

return M
