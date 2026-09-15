-- Pi harness (pi.dev / @earendil-works/pi-coding-agent): per-key entries for the
-- consolidated <leader>c* keymap table in lua/plugins/ai-harness.lua. Each entry is a
-- lazy.nvim key spec (lhs, action, desc, mode/ft).
--
-- pi is NOT the `claude` binary and runs no claudecode websocket server, so claudecode's
-- server-backed commands never reach it. Like claude/copilot/maki, pi runs in OUR own
-- per-harness floating terminal (term.lua) and "adds" files by typing a reference into
-- that terminal's PTY. The shared context-injection machinery (find_terminal_win /
-- shorten_path / type_into_terminal / make_add_command / make_tree_add_command /
-- send_visual_selection) lives in context-inject.lua; this file keeps only pi's
-- build_context_text format and its command registrations.
--
-- pi supports @file mentions (pi --help: `pi @README.md ...`; "Type @ to fuzzy-search
-- files"), so the format mirrors claude: @<path> with a trailing slash for directories,
-- and an optional #L<start>-<end> range. NOTE: pi's support for a #L range appended to an
-- @mention (@path#L1-2) is unverified - whole-file @path is confirmed working; the range
-- form follows the claude/copilot convention.
--
-- No history_spec (<leader>cu): pi has no live JSONL edit-following wired yet (see
-- pi/init.lua), so there is no recorded-edits picker to hang off. Add it when the pi
-- JSONL adapter lands.

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

-- ==========================================================================
-- CONTEXT FORMAT (pi-specific: @<path>, directories keep a trailing slash)
-- ==========================================================================

---Build a pi @-mention for a file/dir/buffer. Directories keep a trailing slash so pi
---treats the reference as a folder. Line ranges use the #L<start>-<end> form (see header note).
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

---pi appends the trailing space inline (no separate write needed); the inline form is what
---the user verified working for whole-file @mentions.
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "pi")
end

-- ==========================================================================
-- USER COMMANDS (our own local commands - no claudecode dependency)
-- ==========================================================================

---PiAdd: adds the current buffer (or an explicit file + line range) as an @<path> mention
---typed into our per-harness float. Usage: PiAdd <file-path> [start-line] [end-line]
ci.make_add_command("PiAdd", "pi", type_into_terminal, build_context_text)

---PiTreeAdd: sends the file(s)/dir(s) under the cursor / selected in neo-tree as @<path>
---mentions. Uses our own neo-tree selector (tree-select) via utils.get_tree_selection.
ci.make_tree_add_command("PiTreeAdd", "pi", type_into_terminal, build_context_text)

---Visual-mode <leader>ca: send the selected lines (path + #L range) to the pi terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (consumed by ai-harness.lua's consolidated keys table)
-- ==========================================================================

return {
  -- <leader>c is wired by keymaps.build() from focus_spec, which triggers the JSONL
  -- watcher; this file does not declare it.
  -- <leader>cc / <leader>cr: continue / resume the last session via OUR per-harness float
  -- (term.lua), not a claudecode command. --continue and --resume are pi's own flags
  -- (pi --help: "--continue, -c" / "--resume, -r").
  keymaps.continue_spec("pi"),
  {
    "<leader>cr",
    function()
      require("harness-decorators.term").open("pi", { args = "--resume" })
    end,
    desc = "Resume Pi",
  },
  { "<leader>ca", "<cmd>PiAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send selection to Pi" },
  keymaps.tree_add_spec("pi", "PiTreeAdd"),
}
