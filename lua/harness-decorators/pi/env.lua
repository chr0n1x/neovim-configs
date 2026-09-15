-- Pi harness env setup: terminal command. Honors PI_COMMAND for a full override (provider/model
-- flags, a wrapper script, etc.); otherwise just runs `pi` interactively. pi resolves its
-- provider/model from its own settings, so there is nothing to thread through here by default.
return require("harness-decorators.utils").command_for("pi", "pi")
