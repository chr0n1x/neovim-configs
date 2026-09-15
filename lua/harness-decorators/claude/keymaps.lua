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
local keymaps = require("harness-decorators.keymaps")

-- ==========================================================================
-- CONTEXT FORMAT (claude-specific: @<path>, directories keep a trailing slash)
-- ==========================================================================

---Build a claude @-mention for a tree node. Directories keep a trailing slash so the CLI
---treats the reference as a folder, not a file.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function build_context_text(file_path, start_line, end_line)
  local is_dir = vim.fn.isdirectory(file_path) == 1
  local short = ci.shorten_path(file_path)
  if is_dir and not short:match("/$") then
    short = short .. "/"
  end
  if start_line and end_line then
    local range = start_line == end_line and ("#L" .. start_line) or ("#L" .. start_line .. "-" .. end_line)
    return "@" .. short .. range
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
---as @<path> mentions typed into the terminal. Uses our own neo-tree selector (tree-select),
-- and formats paths locally so a cwd-equal directory never collapses to a bare "@".
ci.make_tree_add_command("ClaudeTreeAdd", "claude", type_into_terminal, build_context_text)

---ClaudeAdd: adds the current buffer (or an explicit file + line range) as an @<path> mention
-- typed into our per-harness float. Same shared machinery as MakiAdd/CopilotAdd - no claudecode
-- dependency. Usage: ClaudeAdd <file-path> [start-line] [end-line]
ci.make_add_command("ClaudeAdd", "claude", type_into_terminal, build_context_text)

---Visual-mode <leader>ca: send the selected lines (path + #L range) to the claude terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

return {
  -- <leader>c is wired by keymaps.build() from focus_spec, which triggers the JSONL
  -- watcher; this file does not declare it.
  -- <leader>cc: continue the last session. Drives OUR per-harness float (term.lua), not a
  -- claudecode command, so it opens/continues THIS harness's terminal with `--continue`.
  keymaps.continue_spec("claude"),
  keymaps.history_spec("claude"),
  -- <leader>ca: type the buffer's @path into OUR per-harness float (context-inject). Model
  -- switching is done in the CLI itself (/model), not via a plugin command.
  { "<leader>ca", "<cmd>ClaudeAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send to Claude" },
  keymaps.tree_add_spec("claude", "ClaudeTreeAdd"),
}
