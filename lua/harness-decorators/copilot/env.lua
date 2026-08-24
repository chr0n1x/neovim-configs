local cmd_env = os.getenv("COPILOT_COMMAND") or ""
if cmd_env ~= "" then
  return cmd_env
end
return "copilot"
