-- Pig harness: per-key entries for the <leader>c* keymap table. Pig wraps Pi, so the context
-- format matches pi/keymaps.lua: @<path>, a trailing slash for directories, and an optional
-- #L<start>-<end> range.

local ci = require("harness-decorators.context-inject")

return ci.harness_keymaps({
  harness = "pig",
  format = ci.at_mention,
  add = true,
  resume = true,
})
