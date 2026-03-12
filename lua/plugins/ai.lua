local settings = {
  window = {
    position = "float",
    float = {
      width = "25%",
      height = "85%",
      row = "5%",
      col = "70%",
      relative = "editor",  -- Relative to: "editor" or "cursor"
      border = "solid",   -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
    },
  },
}

-- example - override based on env-var
local command = "claude --model qwen3.5:9b"
if OLLAMA_MODEL ~= "" then
  command = "claude --model " .. OLLAMA_MODEL
else
  command = "claude"
end

settings.command = command

return {
  "greggh/claude-code.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim", -- Required for git operations
  },
  config = function()
    require("claude-code").setup(settings)
  end
}
