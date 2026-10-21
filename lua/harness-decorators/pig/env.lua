-- Pig harness env setup: terminal command. Honors PIG_COMMAND for a full override; otherwise
-- runs `pig`, appending --provider/--model from NVIM_LLM_HARNESS_PIG_PROVIDER_NAME /
-- LLAMA_DEFAULT_MODEL when present. With neither set, just runs `pig`.
local cmd_env = os.getenv("PIG_COMMAND") or ""
if cmd_env ~= "" then
  return cmd_env
end
local cmd = "pig"
local provider = os.getenv("NVIM_LLM_HARNESS_PIG_PROVIDER_NAME") or ""
if provider ~= "" then
  cmd = cmd .. " --provider " .. provider
end
local model = os.getenv("LLAMA_DEFAULT_MODEL") or ""
if model ~= "" then
  cmd = cmd .. " --model " .. model
end
return cmd
