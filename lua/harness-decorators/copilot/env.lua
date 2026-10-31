-- Copilot harness env setup: terminal command. Honors COPILOT_COMMAND for a full override;
-- otherwise just runs `copilot` interactively. copilot picks its model from its own config, so
-- there is no model flag to thread through here.
local utils = require("harness-decorators.utils")

return {
  command = function()
    return utils.command_for("copilot", "copilot")
  end,
  prepare_env = function()
    return {}
  end,
}
