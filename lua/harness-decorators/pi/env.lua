-- Pi harness env setup: terminal command. Honors PI_COMMAND for a full override (a wrapper
-- script, etc.); otherwise runs `pi`, appending --provider/--model from
-- NVIM_LLM_HARNESS_PI_PROVIDER_NAME / LLAMA_DEFAULT_MODEL (set in ~/.envrc) when present so the
-- local llama-cpp model wins over pi's own settings. With neither set, just runs `pi`.
local cmd_env = os.getenv("PI_COMMAND") or ""
if cmd_env ~= "" then
  return cmd_env
end
local cmd = "pi"
local provider = os.getenv("NVIM_LLM_HARNESS_PI_PROVIDER_NAME") or ""
if provider ~= "" then
  cmd = cmd .. " --provider " .. provider
end
local model = os.getenv("LLAMA_DEFAULT_MODEL") or ""
if model ~= "" then
  cmd = cmd .. " --model " .. model
end
return cmd
