-- Crush: @-prefixed path references (directories keep a trailing slash); no edit following
-- (SQLite sessions), so no Add or history keys.

local ci = require("harness-decorators.context-inject")

return ci.harness_keymaps({
  harness = "crush",
  format = ci.at_mention,
})
