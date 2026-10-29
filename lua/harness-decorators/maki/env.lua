-- Maki harness env setup: terminal command (CLI + model flags). Honors MAKI_COMMAND for a full
-- override, else appends -m <MAKI_MODEL> when set, else runs `maki` interactively.
return require("harness-decorators.utils").command_for("maki", "maki", "-m ")
