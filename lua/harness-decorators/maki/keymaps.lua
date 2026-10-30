-- Maki: no @file mentions; "adding" a file types a bare path reference into the float.

local ci = require("harness-decorators.context-inject")

---Bare shortened path, optional #L range.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function format(file_path, start_line, end_line)
  return ci.shorten_path(file_path) .. ci.line_range(start_line, end_line)
end

return ci.harness_keymaps({
  harness = "maki",
  format = format,
  add = true,
  history = true,
})
