-- Maki harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). Maki has no @file mention expansion and reads piped stdin as its initial
-- prompt, so "adding" a file means typing a path reference into the floating terminal.
-- The shared context-injection machinery (find_terminal_win / shorten_path /
-- type_into_terminal / make_add_command / make_tree_add_command / send_visual_selection)
-- lives in context-inject.lua; this file keeps only maki's build_context_text format and
-- its command registrations, plus the MakiAdd / MakiTreeAdd user-commands that replace
-- claudecode's server-backed ones.

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

-- ==========================================================================
-- CONTEXT FORMAT (maki-specific: bare path, optional #L<start>-<end> range)
-- ==========================================================================

---Build a path-labeled snippet. Maki reads files itself, so context is always just a path
---reference. Line ranges use the same #L<start>-<end> form claude-code uses (e.g.
---<path>#L31-32), so references look consistent across both harnesses.
---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function build_context_text(file_path, start_line, end_line)
  local short = ci.shorten_path(file_path)
  if not (start_line and end_line) then
    return short
  end
  return start_line == end_line and (short .. "#L" .. start_line) or (short .. "#L" .. start_line .. "-" .. end_line)
end

---maki appends the trailing space inline (no separate write needed).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "maki")
end

-- ==========================================================================
-- USER COMMANDS (replace claudecode's server-backed ClaudeCodeAdd/TreeAdd)
-- ==========================================================================

---MakiAdd: adds a file (or line range) to the maki terminal as a path reference.
---Usage: MakiAdd <file-path> [start-line] [end-line]
ci.make_add_command("MakiAdd", "maki", type_into_terminal, build_context_text)

---MakiTreeAdd: sends the file(s) under the cursor / selected in the tree plugin as bare
---path references. Reuses claudecode.nvim's server-independent tree detection.
ci.make_tree_add_command("MakiTreeAdd", "maki", type_into_terminal, build_context_text)

-- Visual-mode <leader>ca: send the selected lines (path + range) to the maki terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (consumed by ai-harness.lua's consolidated keys table)
-- ==========================================================================

return {
  -- <leader>c is wired by keymaps.build() from focus_spec, which triggers the JSONL
  -- watcher; this file does not declare it.
  -- <leader>cc: continue the last session via OUR per-harness float (term.lua), not a claudecode cmd.
  keymaps.continue_spec("maki"),
  keymaps.history_spec("maki"),
  { "<leader>ca", "<cmd>MakiAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send selection to Maki" },
  keymaps.tree_add_spec("maki", "MakiTreeAdd"),
}
