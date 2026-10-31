-- Copilot harness env setup: terminal command. Honors COPILOT_COMMAND for a full override;
-- otherwise runs `copilot` (it picks its model from its own config).
local utils = require("harness-decorators.utils")

return {
  command = function()
    return utils.command_for("copilot", "copilot")
  end,
  prepare_env = function()
    return {}
  end,
}
