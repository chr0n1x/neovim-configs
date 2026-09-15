-- Neo-tree file selection for the <C-t> tree-add command (all harnesses).
--
-- This is a self-contained port of the neo-tree branch of claudecode.nvim's
-- integrations.get_selected_files_from_tree, so <C-t> no longer depends on that
-- plugin. It reads the live neo-tree filesystem state directly and returns a list
-- of ABSOLUTE file/dir paths - never a buffer name or filetype like "neo-tree".
-- A regression that returned the buffer name produced "not a readable file:
-- neo-tree" when <C-t> fired in neo-tree (see tests/tree_selection_spec.lua).
local M = {}

---Read the current neo-tree filesystem state, or nil if neo-tree isn't open.
---@return table|nil state
local function get_state()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return nil
  end
  return manager.get_state("filesystem")
end

---Collect file/dir paths from a visual selection in the neo-tree window. Uses
--neo-tree's own line-to-node mapping over the visual range (the same approach its
--copy/paste feature uses). Skips root-level nodes (depth <= 1) so selecting the
--tree root doesn't add a bare directory.
---@param state table neo-tree filesystem state
---@return table files absolute paths
local function from_visual(state)
  local files = {}
  if not (state.winid and state.winid == vim.api.nvim_get_current_win()) then
    return files
  end

  -- Visual range from the '< / '> marks, falling back to cursor + v anchor.
  local start_pos = vim.fn.getpos("'<")[2]
  local end_pos = vim.fn.getpos("'>")[2]
  if start_pos == 0 or end_pos == 0 then
    local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
    local anchor_pos = vim.fn.getpos("v")[2]
    if anchor_pos > 0 then
      start_pos = math.min(cursor_pos, anchor_pos)
      end_pos = math.max(cursor_pos, anchor_pos)
    else
      start_pos = cursor_pos
      end_pos = cursor_pos
    end
  end
  if end_pos < start_pos then
    start_pos, end_pos = end_pos, start_pos
  end

  for line = start_pos, end_pos do
    local node = state.tree and state.tree:get_node(line)
    if node and node.type and node.type ~= "message" then
      local depth = (node.get_depth and node:get_depth()) or 0
      if depth > 1 and node.path and node.path ~= "" and (node.type == "file" or node.type == "directory") then
        table.insert(files, node.path)
      end
    end
  end
  return files
end

---Collect file paths from neo-tree's tracked selection (the nodes the user has
--explicitly selected via its own selection mechanism).
---@param state table neo-tree filesystem state
---@return table files absolute paths
local function from_state_selection(state)
  local files = {}
  if not state.tree then
    return files
  end
  local selection = state.tree.get_selection and state.tree:get_selection() or nil
  if (not selection or #selection == 0) and state.selected_nodes then
    selection = state.selected_nodes
  end
  for _, node in ipairs(selection or {}) do
    if node.type == "file" and node.path and node.path ~= "" then
      table.insert(files, node.path)
    end
  end
  return files
end

---The single node under the cursor (normal-mode fallback). Accepts both file and
--directory nodes.
---@param state table neo-tree filesystem state
---@return string|nil path
local function from_cursor(state)
  if not state.tree then
    return nil
  end
  local node = state.tree:get_node()
  if node and node.path and node.path ~= "" and (node.type == "file" or node.type == "directory") then
    return node.path
  end
  return nil
end

---Resolve the file(s)/dir(s) selected in neo-tree. Tries, in order: a visual
--selection, neo-tree's tracked selection, then the node under the cursor.
---@return table files list of absolute paths (empty when nothing is selected)
---@return string|nil err error message when no selection could be resolved
function M.get_selected()
  local state = get_state()
  if not state then
    return {}, "neo-tree filesystem state not available"
  end

  local mode = vim.fn.mode()
  if mode == "V" or mode == "v" or mode == "\22" then
    local files = from_visual(state)
    if #files > 0 then
      return files, nil
    end
  end

  local files = from_state_selection(state)
  if #files > 0 then
    return files, nil
  end

  local path = from_cursor(state)
  if path then
    return { path }, nil
  end

  return {}, "No file found under cursor"
end

return M
