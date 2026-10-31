-- Maki harness env setup: terminal command (CLI + model flags). Honors MAKI_COMMAND for a full
-- override, else appends -m <MAKI_MODEL> when set, else runs `maki` interactively.
local utils = require("harness-decorators.utils")

return {
  command = function()
    return utils.command_for("maki", "maki", "-m ")
  end,
  prepare_env = function()
    return {}
  end,
}
