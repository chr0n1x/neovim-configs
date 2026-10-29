-- Pig harness: per-key entries for the <leader>c* keymap table. Pig wraps Pi, so the context
-- format matches pi/keymaps.lua: @<path>, a trailing slash for directories, and an optional
-- #L<start>-<end> range.

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

---@param file_path string
---@param start_line? integer
---@param end_line? integer
---@return string
local function build_context_text(file_path, start_line, end_line)
  return ci.at_mention(file_path, start_line, end_line)
end

local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "pig")
end

---PigAdd <file-path> [start-line] [end-line]
ci.make_add_command("PigAdd", "pig", type_into_terminal, build_context_text)

---PigTreeAdd: sends the neo-tree selection as @<path> mentions.
ci.make_tree_add_command("PigTreeAdd", "pig", type_into_terminal, build_context_text)

local send_selection = ci.send_visual_selection(type_into_terminal, build_context_text)

return {
  keymaps.continue_spec("pig"),
  {
    "<leader>cr",
    function()
      require("harness-decorators.term").open("pig", { args = "--resume" })
    end,
    desc = "Resume Pig",
  },
  { "<leader>ca", "<cmd>PigAdd %<cr>", desc = "Add current buffer" },
  { "<leader>ca", send_selection, mode = "v", desc = "Send selection to Pig" },
  keymaps.tree_add_spec("pig", "PigTreeAdd"),
}
