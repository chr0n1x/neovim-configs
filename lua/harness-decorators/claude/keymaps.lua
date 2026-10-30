-- Claude: @<path> mentions (directories keep a trailing slash), optional #L range.

local ci = require("harness-decorators.context-inject")

return ci.harness_keymaps({
  harness = "claude",
  format = ci.at_mention,
  add = true,
  history = true,
})
