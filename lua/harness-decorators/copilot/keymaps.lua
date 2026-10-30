-- Copilot: " @<path>" mentions, optional #L range. The trailing space goes in a separate
-- chansend because copilot's line editor can drop trailing whitespace that arrives in the
-- same PTY write as an @file reference.

local ci = require("harness-decorators.context-inject")

---Build a Copilot @file mention, e.g. " @<path>#L31-32".
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function format(file_path, start_line, end_line)
  return " @" .. ci.shorten_path(file_path) .. ci.line_range(start_line, end_line)
end

return ci.harness_keymaps({
  harness = "copilot",
  format = format,
  separate_space = true,
  add = true,
  history = true,
})
