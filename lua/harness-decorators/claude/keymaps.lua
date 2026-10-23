-- Claude: @<path> mentions (dirs keep a trailing slash), optional #L range.

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
  return ci.at_mention(file_path, start_line, end_line)
end

---claude appends the trailing space inline (no separate write needed).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "claude")
end

-- ==========================================================================
-- USER COMMANDS
-- ==========================================================================

---ClaudeTreeAdd: sends the file(s)/dir(s) under the cursor / selected in the tree plugin
---as @<path> mentions typed into the terminal. Paths are absolute, so a cwd-equal directory
---never collapses to a bare "@".
ci.make_tree_add_command("ClaudeTreeAdd", "claude", type_into_terminal, build_context_text)

---ClaudeAdd: adds the current buffer (or an explicit file + line range) as an @<path> mention
---typed into the harness float. Usage: ClaudeAdd <file-path> [start-line] [end-line]
ci.make_add_command("ClaudeAdd", "claude", type_into_terminal, build_context_text)

---Visual-mode <leader>ca: send the selected lines (path + #L range) to the claude terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

return {
  -- <leader>cc: open this harness's float with `--continue`.
  keymaps.continue_spec("claude"),
  keymaps.history_spec("claude"),
  -- <leader>ca: type the buffer's @path into the harness float.
  { "<leader>ca", "<cmd>ClaudeAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send to Claude" },
  keymaps.tree_add_spec("claude", "ClaudeTreeAdd"),
}
