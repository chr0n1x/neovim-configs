-- Pi harness (pi.dev / @earendil-works/pi-coding-agent): per-key entries for the
-- <leader>c* keymap table merged by harness-decorators/keymaps.lua.
--
-- pi supports @file mentions (pi --help: `pi @README.md ...`; "Type @ to fuzzy-search
-- files"), so the format mirrors claude: @<path> with a trailing slash for directories,
-- and an optional #L<start>-<end> range. NOTE: pi's support for a #L range appended to an
-- @mention (@path#L1-2) is unverified - whole-file @path is confirmed working; the range
-- form follows the claude/copilot convention.

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
  return ci.at_mention(file_path, start_line, end_line)
end

---Space appended inline.
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "pi")
end

-- ==========================================================================
-- USER COMMANDS
-- ==========================================================================

---PiAdd: adds the current buffer (or an explicit file + line range) as an @<path> mention
---typed into the harness float. Usage: PiAdd <file-path> [start-line] [end-line]
ci.make_add_command("PiAdd", "pi", type_into_terminal, build_context_text)

---PiTreeAdd: sends the file(s)/dir(s) under the cursor / selected in neo-tree as @<path>
---mentions. Uses our own neo-tree selector (tree-select) via utils.get_tree_selection.
ci.make_tree_add_command("PiTreeAdd", "pi", type_into_terminal, build_context_text)

---Visual-mode <leader>ca: send the selected lines (path + #L range) to the pi terminal.
local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (merged by harness-decorators/keymaps.lua)
-- ==========================================================================

return {
  -- <leader>cc / <leader>cr: open the float with pi's --continue / --resume flags.
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
  keymaps.history_spec("pi"),
  keymaps.tree_add_spec("pi", "PiTreeAdd"),
}
