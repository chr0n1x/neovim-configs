-- Crush harness env setup: terminal command. Honors CRUSH_COMMAND for a full override (extra
-- flags, a wrapper script); otherwise runs `crush` (it picks its model from its own config).
local utils = require("harness-decorators.utils")

return {
  command = function()
    return utils.command_for("crush", "crush")
  end,
  prepare_env = function()
    return {}
  end,
}
