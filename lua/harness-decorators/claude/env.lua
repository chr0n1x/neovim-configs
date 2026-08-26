-- Claude harness env setup: terminal command (CLI + model flags).
-- NOTE: make sure the model can use tools.
local cmd_env = os.getenv("CLAUDE_COMMAND") or ""
local model = os.getenv("CLAUDE_MODEL") or ""
vim.fn.setenv("CLAUDE_CODE_TRACKING_ENABLED", "false")
if cmd_env ~= "" then
  return cmd_env
end

-- point Claude Code at the local server only when a model is set;
-- otherwise leave the env untouched so the default claude setup works
if model ~= "" then
  vim.fn.setenv("ANTHROPIC_BASE_URL", os.getenv("ANTHROPIC_BASE_URL") or "http://localhost:11434")
  if not vim.env.ANTHROPIC_API_KEY then
    vim.fn.setenv("ANTHROPIC_API_KEY", "")
  end
  if not vim.env.ANTHROPIC_AUTH_TOKEN then
    vim.fn.setenv("ANTHROPIC_AUTH_TOKEN", "ollama")
  end
  return "claude --model " .. model
end

return "claude"
