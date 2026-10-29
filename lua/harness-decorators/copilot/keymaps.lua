-- Copilot: " @<path>" mentions, optional #L range. The trailing space goes in a separate
-- chansend because copilot's line editor can drop trailing whitespace that arrives in the
-- same PTY write as an @file reference.

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

-- ==========================================================================
-- CONTEXT FORMAT (copilot-specific: " @<path>", optional #L<start>-<end> range)
-- ==========================================================================

---Build a Copilot @file mention, e.g. @<path>#L31-32.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function build_context_text(file_path, start_line, end_line)
  return " @" .. ci.shorten_path(file_path) .. ci.line_range(start_line, end_line)
end

---Copilot sends the trailing space as its own PTY write (see file header).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, { separate_space = true }, "copilot")
end

-- ==========================================================================
-- USER COMMANDS
-- ==========================================================================

---CopilotAdd: adds a file (or line range) to the copilot terminal as a path reference.
---Usage: CopilotAdd <file-path> [start-line] [end-line]
ci.make_add_command("CopilotAdd", "copilot", type_into_terminal, build_context_text)

---CopilotTreeAdd: sends the file(s) under the cursor / selected in the tree plugin as
---@path references (selection via utils.get_tree_selection).
ci.make_tree_add_command("CopilotTreeAdd", "copilot", type_into_terminal, build_context_text)

-- Visual-mode <leader>ca: send the selected lines (path + range) to the copilot terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (merged by harness-decorators/keymaps.lua)
-- ==========================================================================

return {
  -- <leader>cc: open this harness's float with `--continue`.
  keymaps.continue_spec("copilot"),
  keymaps.history_spec("copilot"),
  { "<leader>ca", "<cmd>CopilotAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send selection to Copilot" },
  keymaps.tree_add_spec("copilot", "CopilotTreeAdd"),
}
