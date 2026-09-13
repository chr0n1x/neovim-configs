-- Copilot harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). Copilot supports @file mentions, but isn't the real `claude` binary, so
-- claudecode.nvim's server-backed ClaudeCodeAdd/ClaudeCodeSend do nothing. The shared
-- context-injection machinery (find_terminal_win / shorten_path / type_into_terminal /
-- make_add_command / make_tree_add_command / send_visual_selection) lives in
-- context-inject.lua; this file keeps only copilot's build_context_text format and its
-- command registrations. Copilot is the one harness that sends the trailing space as a
-- SEPARATE chansend (its line editor can discard trailing whitespace when it arrives in
-- the same PTY write as an @file reference), so its type_into_terminal passes
-- separate_space = true.

local ci = require("harness-decorators.context-inject")

-- ==========================================================================
-- CONTEXT FORMAT (copilot-specific: " @<path>", optional #L<start>-<end> range)
-- ==========================================================================

---Build a Copilot @file mention. Line ranges use the same #L<start>-<end> form
---Claude Code uses (e.g. @<path>#L31-32), so references look consistent across
---harnesses.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function build_context_text(file_path, start_line, end_line)
  local short = ci.shorten_path(file_path)
  if not (start_line and end_line) then
    return " @" .. short
  end
  local range = start_line == end_line and ("#L" .. start_line) or ("#L" .. start_line .. "-" .. end_line)
  return " @" .. short .. range
end

---Copilot sends the trailing space as its own PTY write (see file header).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, { separate_space = true }, "copilot")
end

-- ==========================================================================
-- USER COMMANDS (replace claudecode's server-backed ClaudeCodeAdd/TreeAdd)
-- ==========================================================================

---CopilotAdd: adds a file (or line range) to the copilot terminal as a path reference.
---Usage: CopilotAdd <file-path> [start-line] [end-line]
ci.make_add_command("CopilotAdd", "copilot", type_into_terminal, build_context_text)

---CopilotTreeAdd: sends the file(s) under the cursor / selected in the tree plugin as
---@path references. Reuses claudecode.nvim's server-independent tree detection.
ci.make_tree_add_command("CopilotTreeAdd", "copilot", type_into_terminal, build_context_text)

-- Visual-mode <leader>ca: send the selected lines (path + range) to the copilot terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (consumed by ai-harness.lua's consolidated keys table)
-- ==========================================================================

return {
  { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Copilot", mode = { "n", "x" } },
  -- <leader>cc: continue the last session via OUR per-harness float (term.lua), not a claudecode cmd.
  {
    "<leader>cc",
    function()
      require("harness-decorators.term").open("copilot", { args = "--continue" })
    end,
    desc = "Continue Copilot",
  },
  {
    "<leader>cu",
    function()
      require("harness-decorators.telescope-history-picker").pick()
    end,
    desc = "View changes made by copilot",
    mode = { "n" },
  },
  { "<leader>ca", "<cmd>CopilotAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send selection to Copilot" },
  {
    "<C-t>",
    "<cmd>CopilotTreeAdd<cr>",
    desc = "Add file to Copilot",
    ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
  },
}
