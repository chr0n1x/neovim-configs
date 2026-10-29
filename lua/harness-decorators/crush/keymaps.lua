-- Crush: @-prefixed path references; no edit following (SQLite sessions).

local ci = require("harness-decorators.context-inject")
local keymaps = require("harness-decorators.keymaps")

-- ==========================================================================
-- CONTEXT FORMAT (crush-specific: bare path, directories keep a trailing slash)
-- ==========================================================================

---Build a crush path reference: `@`-prefixed shortened path (directories keep a trailing
---slash so they read as a folder, not a file).
---@param file_path string
---@return string
local function build_context_text(file_path)
  local short = ci.shorten_path(file_path)
  if vim.fn.isdirectory(file_path) == 1 and not short:match("/$") then
    short = short .. "/"
  end
  return "@" .. short
end

---crush appends the trailing space inline (no separate write needed).
local function type_into_terminal(text)
  return ci.type_into_terminal(text, nil, "crush")
end

-- ==========================================================================
-- USER COMMAND (tree add for <C-t>)
-- ==========================================================================

---CrushTreeAdd: sends the file(s)/dir(s) under the cursor / selected in the tree plugin
---as bare path references typed into the crush terminal (selection via
---utils.get_tree_selection).
ci.make_tree_add_command("CrushTreeAdd", "crush", type_into_terminal, build_context_text)

-- ==========================================================================
-- PER-KEY ENTRIES (merged by harness-decorators/keymaps.lua)
-- ==========================================================================

return {
  -- <leader>cc: open this harness's float with `--continue`.
  keymaps.continue_spec("crush"),
  keymaps.tree_add_spec("crush", "CrushTreeAdd"),
}
