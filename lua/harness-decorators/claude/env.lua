-- Claude harness env setup: terminal command, plus job-local env defaults (neither function
-- changes nvim's own env).
-- NOTE: make sure the model can use tools.
local utils = require("harness-decorators.utils")
local M = {}

function M.command()
  return utils.command_for("claude", "claude", "--model ")
end

function M.prepare_env()
  if (os.getenv("CLAUDE_COMMAND") or "") ~= "" then
    return {}
  end
  local env = { CLAUDE_CODE_TRACKING_ENABLED = "false" }
  if (os.getenv("CLAUDE_MODEL") or "") ~= "" then
    -- Inherited values stay out of Snacks' inspectable job metadata, including empty values.
    for key, default in pairs({
      ANTHROPIC_BASE_URL = "http://localhost:11434",
      ANTHROPIC_API_KEY = "",
      ANTHROPIC_AUTH_TOKEN = "ollama",
    }) do
      if os.getenv(key) == nil then
        env[key] = default
      end
    end
  end
  return env
end

return M
