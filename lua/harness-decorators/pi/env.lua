-- Pi harness env setup: terminal command. Honors PI_COMMAND for a full override;
-- otherwise runs `pi`, appending --provider/--model from NVIM_LLM_HARNESS_PI_PROVIDER_NAME /
-- LLAMA_DEFAULT_MODEL when present so the local llama-cpp model wins over the harness's own
-- settings. See utils.provider_command.
return require("harness-decorators.utils").provider_command("pi")
