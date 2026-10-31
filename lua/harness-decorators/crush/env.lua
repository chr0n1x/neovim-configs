-- Crush harness env setup: terminal command. Honors CRUSH_COMMAND for a full override (extra flags,
-- a wrapper script, etc.); otherwise just runs `crush` interactively. crush picks its model from
-- its own config, so there is no model flag to thread through here.
local utils = require("harness-decorators.utils")

return {
  command = function()
    return utils.command_for("crush", "crush")
  end,
  prepare_env = function()
    return {}
  end,
}
