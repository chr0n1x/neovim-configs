-- Crush harness env setup: terminal command. Honors CRUSH_COMMAND for a full
-- override (extra flags, a wrapper script, etc.); otherwise just runs `crush`
-- interactively. crush picks its model from its own config, so there is no
-- model flag to thread through here.
local cmd_env = os.getenv("CRUSH_COMMAND") or ""
if cmd_env ~= "" then
  return cmd_env
end
return "crush"
