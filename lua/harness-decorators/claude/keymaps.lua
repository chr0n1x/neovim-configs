-- Claude harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). The binding strings and descriptions are harness-specific; ai-harness.lua
-- just concatenates these into its single keys table. The claude harness otherwise uses
-- claudecode.nvim's stock commands as-is, EXCEPT <C-t> tree-add: the stock
-- ClaudeCodeTreeAdd routes through _format_path_for_at_mention, which collapses a
-- directory equal to nvim's cwd to "./", and the CLI then relativizes that against its
-- own (stale) spawn cwd to an empty string - producing a bare "@" in the terminal. So
-- <C-t> uses a local ClaudeTreeAdd that types an unambiguous @<path> mention directly
-- into the terminal (same approach as the maki/copilot harnesses).
--
-- The shared context-injection machinery (find_terminal_win / shorten_path /
-- type_into_terminal / make_tree_add_command) lives in context-inject.lua; this file keeps
-- only claude's build_context_text format and its command registrations.

local ci = require("harness-decorators.context-inject")

-- ==========================================================================
-- CONTEXT FORMAT (claude-specific: @<path>, directories keep a trailing slash)
-- ==========================================================================

---Build a claude @-mention for a tree node. Directories keep a trailing slash so the CLI
---treats the reference as a folder, not a file.
---@param file_path string
---@return string
local function build_context_text(file_path)
  local is_dir = vim.fn.isdirectory(file_path) == 1
  local short = ci.shorten_path(file_path)
  if is_dir and not short:match("/$") then
    short = short .. "/"
  end
  return "@" .. short
end

---claude appends the trailing space inline (no separate write needed).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "claude")
end

-- ==========================================================================
-- USER COMMAND (replaces claudecode's server-backed ClaudeCodeTreeAdd for <C-t>)
-- ==========================================================================

---ClaudeTreeAdd: sends the file(s)/dir(s) under the cursor / selected in the tree plugin
---as @<path> mentions typed into the terminal. Reuses claudecode.nvim's server-independent
---tree detection, but formats paths locally so a cwd-equal directory never collapses to a
---bare "@".
ci.make_tree_add_command("ClaudeTreeAdd", "claude", type_into_terminal, build_context_text)

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
    desc = "view list of changes claude made.",
    mode = { "n" },
  },
  { "<leader>ca", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
  -- esc required to exit visual mode after going into terminal
  { "<leader>ca", "<cmd>ClaudeCodeSend<cr>; <esc>", mode = "v", desc = "Send to Claude" },
  {
    "<C-t>",
    "<cmd>ClaudeTreeAdd<cr>",
    desc = "Add file",
    ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
  },
  -- Diff management - I barely use these but wanted to give some defaults
  -- that fall under <leader>c
  { "<leader>cda", "<cmd>ClaudeCodeDiffAccept<cr>; redraw<cr>", desc = "Accept diff & redraw" },
  { "<leader>cdd", "<cmd>ClaudeCodeDiffDeny<cr>; redraw<cr>", desc = "Deny diff & redraw" },
}
