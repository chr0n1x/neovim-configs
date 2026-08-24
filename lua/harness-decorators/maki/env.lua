-- Maki harness env setup: terminal command (CLI + model flags).
local cmd_env = os.getenv("MAKI_COMMAND") or ""
local model = os.getenv("MAKI_MODEL") or ""
if cmd_env ~= "" then
  return cmd_env
elseif model ~= "" then
  return "maki -m " .. model
end
return "maki"
