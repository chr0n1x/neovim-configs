-- Crush harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Each entry is a lazy.nvim key spec (lhs, action, desc,
-- mode/ft). crush is a self-contained TUI: it reads files itself (no @file mention
-- server) and stores sessions in SQLite rather than JSONL, so the live edit-following
-- watcher is disabled for it (see crush/init.lua). That leaves nothing for the
-- copilot/maki-style edit-history picker to hang off, but <C-t> tree-add still makes
-- sense: type the selected path into the crush terminal as a bare reference you can
-- weave into your prompt. The shared context-injection machinery (find_terminal_win /
-- shorten_path / type_into_terminal / make_tree_add_command) lives in context-inject.lua;
-- this file keeps only crush's build_context_text format and its command registrations.

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

-- ==========================================================================
-- CONTEXT FORMAT (crush-specific: bare path, directories keep a trailing slash)
-- ==========================================================================

---Build a crush path reference. crush has no @file mention syntax, so this is just the
---shortened path (no leading @). A directory keeps a trailing slash so it reads as a
---folder, not a file.
---@param file_path string
---@return string
local function build_context_text(file_path)
  local short = ci.shorten_path(file_path)
  if vim.fn.isdirectory(file_path) == 1 and not short:match("/$") then
    short = short .. "/"
  end
  return short
end

---crush appends the trailing space inline (no separate write needed).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "crush")
end

-- ==========================================================================
-- USER COMMAND (tree add for <C-t>)
-- ==========================================================================

---CrushTreeAdd: sends the file(s)/dir(s) under the cursor / selected in the tree plugin
---as bare path references typed into the crush terminal. Reuses claudecode.nvim's
---server-independent tree detection, but formats paths locally (crush has no @file
---mention server to route through).
ci.make_tree_add_command("CrushTreeAdd", "crush", type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (consumed by ai-harness.lua's consolidated keys table)
-- ==========================================================================

return {
  -- <leader>c is wired by keymaps.build() from focus_spec, which triggers the JSONL
  -- watcher; this file does not declare it.
  -- <leader>cc: continue the last session via OUR per-harness float (term.lua), not a claudecode cmd.
  keymaps.continue_spec("crush"),
  keymaps.tree_add_spec("crush", "CrushTreeAdd"),
}
