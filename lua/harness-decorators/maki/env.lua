-- Maki harness env setup: terminal command. Honors MAKI_COMMAND for a full override; otherwise
-- runs `maki`, appending -m <MAKI_MODEL> when MAKI_MODEL is set.
local utils = require("harness-decorators.utils")

return {
  command = function()
    return utils.command_for("maki", "maki", "-m ")
  end,
  prepare_env = function()
    return {}
  end,
}
