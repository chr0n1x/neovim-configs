-- Pig harness: per-key entries for the consolidated <leader>c* keymap table in
-- lua/plugins/ai-harness.lua. Pig wraps Pi, so the context format matches pi/keymaps.lua:
-- @<path>, a trailing slash for directories, and an optional #L<start>-<end> range.

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

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
