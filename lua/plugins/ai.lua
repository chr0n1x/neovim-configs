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

  keymaps = {
    toggle = {
      normal = "<leader>cn",       -- Normal mode keymap for toggling Claude Code, false to disable
      terminal = "<leader>ct",     -- Terminal mode keymap for toggling Claude Code, false to disable
      variants = {
        continue = "<leader>c", -- Normal mode keymap for Claude Code with continue flag
        verbose = "<leader>cV",  -- Normal mode keymap for Claude Code with verbose flag
      },
    },
    window_navigation = true, -- Enable window navigation keymaps (<C-h/j/k/l>)
    scrolling = true,         -- Enable scrolling keymaps (<C-f/b>) for page up/down
  }
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
