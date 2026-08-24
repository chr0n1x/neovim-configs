-- Claude harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). The binding strings and descriptions are harness-specific; ai-harness.lua
-- just concatenates these into its single keys table.
return {
  { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
  { "<leader>cr", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
  { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
  { "<leader>cm", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
  {
    "<leader>cu",
    function()
      require("harness-decorators.telescope-history-picker").pick()
    end,
    desc = " view list of changes claude made.",
    mode = { "n" },
  },
  { "<leader>ca", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
  -- esc required to exit visual mode after going into terminal
  { "<leader>ca", "<cmd>ClaudeCodeSend<cr>; <esc>", mode = "v", desc = "Send to Claude" },
  {
    "<C-t>",
    "<cmd>ClaudeCodeTreeAdd<cr>",
    desc = "Add file",
    ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
  },
  -- Diff management - I barely use these but wanted to give some defaults
  -- that fall under <leader>c
  { "<leader>cda", "<cmd>ClaudeCodeDiffAccept<cr>; redraw<cr>", desc = "Accept diff & redraw" },
  { "<leader>cdd", "<cmd>ClaudeCodeDiffDeny<cr>; redraw<cr>", desc = "Deny diff & redraw" },
}
