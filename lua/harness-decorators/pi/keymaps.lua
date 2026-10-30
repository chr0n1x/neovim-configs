-- Pi harness (pi.dev / @earendil-works/pi-coding-agent): per-key entries for the
-- <leader>c* keymap table merged by harness-decorators/keymaps.lua.
--
-- pi supports @file mentions (pi --help: `pi @README.md ...`; "Type @ to fuzzy-search
-- files"), so the format mirrors claude: @<path> with a trailing slash for directories,
-- and an optional #L<start>-<end> range. NOTE: pi's support for a #L range appended to an
-- @mention (@path#L1-2) is unverified - whole-file @path is confirmed working; the range
-- form follows the claude/copilot convention.

local ci = require("harness-decorators.context-inject")

return ci.harness_keymaps({
  harness = "pi",
  format = ci.at_mention,
  add = true,
  history = true,
  resume = true,
})
