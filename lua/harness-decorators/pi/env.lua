-- Pi harness env setup: terminal command. Honors PI_COMMAND for a full override
-- (provider/model flags, a wrapper script, etc.); otherwise just runs `pi`
-- interactively. pi resolves its provider/model from its own settings, so there
-- is nothing to thread through here by default.
local cmd_env = os.getenv("PI_COMMAND") or ""
if cmd_env ~= "" then
  return cmd_env
end
return "pi"
