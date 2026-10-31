-- Showing the active harness and listing live ones over state.table; term.lua owns the instances.
local M = {}

local state = require("harness-decorators.state")
local term = require("harness-decorators.term")
local active = require("harness-decorators.active")

---The <leader>c entry point: show the active harness's own float, re-showing the SAME live process
---if one exists, or spawning fresh with its command if not (term.open handles both). Returns the
---harness name shown, or nil when term.open fails.
---@return string? shown
function M.show_selected()
  local harness = active.get()
  if not term.open(harness) then
    return nil
  end
  return harness
end

---Live harnesses for the picker (see term.list).
---@return { harness: string, buff_nr: number }[]
function M.list()
  local out = {}
  for _, e in ipairs(term.list()) do
    table.insert(out, { harness = e.harness, buff_nr = e.bufnr })
  end
  return out
end

---Test-only: clear the shared state table without touching any buffer.
function M._reset()
  state._reset()
end

return M
