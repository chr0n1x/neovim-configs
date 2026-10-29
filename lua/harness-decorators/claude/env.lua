-- Claude harness env setup: terminal command (CLI + model flags).
-- NOTE: make sure the model can use tools.
local utils = require("harness-decorators.utils")

-- CLAUDE_COMMAND is a full override handled by command_for; check it first so the Ollama env
-- side-effect below only runs when we actually build a `claude --model` command ourselves.
if (os.getenv("CLAUDE_COMMAND") or "") ~= "" then
  return utils.command_for("claude", "claude", "--model ")
end

vim.fn.setenv("CLAUDE_CODE_TRACKING_ENABLED", "false")
local model = os.getenv("CLAUDE_MODEL") or ""

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
end

return utils.command_for("claude", "claude", "--model ")
