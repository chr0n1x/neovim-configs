-- Claude harness env setup: terminal command (CLI + model flags).
-- NOTE: make sure the model can use tools.
local cmd_env = os.getenv("CLAUDE_COMMAND") or ""
local model = os.getenv("CLAUDE_MODEL") or ""
vim.fn.setenv("CLAUDE_CODE_TRACKING_ENABLED", "false")
if cmd_env ~= "" then
  return cmd_env
end

-- point Claude Code at the local server when a model is set;
-- fall back to whatever's already in the shell env
vim.fn.setenv("ANTHROPIC_BASE_URL", os.getenv("ANTHROPIC_BASE_URL") or "http://localhost:11434")
if not vim.env.ANTHROPIC_API_KEY then vim.fn.setenv("ANTHROPIC_API_KEY", "") end
if not vim.env.ANTHROPIC_AUTH_TOKEN then vim.fn.setenv("ANTHROPIC_AUTH_TOKEN", "ollama") end

return model ~= "" and ("claude --model " .. model) or "claude"
