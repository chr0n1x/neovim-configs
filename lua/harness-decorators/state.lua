-- Per-harness terminal state shared by term.lua and park.lua: the snacks.terminal float, the
-- directory the harness was started in, and its start time (os.time()), keyed by harness name.
--
--   {
--     maki = { inst = <snacks.terminal>, cwd = "/Users/kran/Code/app", opened_at = 1793376000 },
--     pi = { inst = nil },
--   }
--
-- inst is nil until the float is first opened; cwd and opened_at are absent until the harness starts.
-- term owns .inst, .cwd and .opened_at. Where the float is (its layout:
-- normal, fullscreen, shelved or minimized) lives on the instance, read with layout.get(entry.inst)
-- and changed only through layout.set.
local M = {}

---Per-harness records keyed by harness name.
M.table = {}

---The record for `harness`, created if absent (inst=nil).
---@param harness string
---@return table entry { inst = snacks.terminal|nil }
function M.entry(harness)
  local e = M.table[harness]
  if not e then
    e = { inst = nil }
    M.table[harness] = e
  end
  return e
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
