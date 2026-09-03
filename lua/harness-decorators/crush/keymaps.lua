-- Crush harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action,
-- desc, mode/ft).
--
-- Barebones on purpose. crush is a self-contained TUI: it reads files itself
-- (no @file mention server to inject context into) and stores sessions in SQLite
-- rather than JSONL, so the live edit-following watcher is disabled for it (see
-- crush/init.lua). That leaves nothing for the copilot/maki-style context
-- injection or edit-history picker to hang off, so this is just open/focus and
-- continue.
return {
  { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Crush", mode = { "n", "x" } },
  { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Crush" },
}
