-- Shared diff helpers for the harness adapters. Both maki and copilot render a unified-style
-- diff from two full-file text blobs, and both needed find_starting_line (first divergent line)
-- and diff_full_files (numbered prefix/suffix diff). The output format of diff_full_files is a
-- de-facto contract: the history picker's highlighter (telescope-history-picker.lua) parses it,
-- expecting "%5d  <prefix><content>" with the prefix char always at string position 8. Do NOT
-- change that format string without updating the picker in lockstep.
local M = {}

---Find the first divergent line between two full-file text blobs (1-indexed).
---@param before string Full file content before edit
---@param after string Full file content after edit
---@return integer? starting_line 1-based line number of first change, or nil
function M.find_starting_line(before, after)
  local before_lines = vim.split(before, "\n", { plain = true })
  local after_lines = vim.split(after, "\n", { plain = true })
  local max_len = math.min(#before_lines, #after_lines)
  for i = 1, max_len do
    if before_lines[i] ~= after_lines[i] then
      return i
    end
  end
  -- All common lines match; change is at the boundary (insertion or deletion).
  if #before_lines ~= #after_lines then
    return max_len + 1
  end
  return nil
end

---Compute a unified-style diff from two full-file text blobs. Returns lines in the
---"%5d  <prefix><content>" format consumed by the previewer's highlighter (see module
---header). Context is up to 3 lines before and after the change; deletions are prefixed
---with "-", additions with "+", context with a space.
---@param before string Full file content before edit
---@param after string Full file content after edit
---@return string[] numbered diff lines
function M.diff_full_files(before, after)
  local before_lines = vim.split(before, "\n", { plain = true })
  local after_lines = vim.split(after, "\n", { plain = true })

  -- Find common prefix.
  local prefix_len = 0
  local max_prefix = math.min(#before_lines, #after_lines)
  for i = 1, max_prefix do
    if before_lines[i] == after_lines[i] then
      prefix_len = i
    else
      break
    end
  end

  -- Find common suffix (not overlapping with prefix).
  local suffix_len = 0
  local max_suffix = math.min(#before_lines, #after_lines) - prefix_len
  for i = 1, max_suffix do
    if before_lines[#before_lines - i + 1] == after_lines[#after_lines - i + 1] then
      suffix_len = i
    else
      break
    end
  end

  -- Build the numbered diff.
  local numbered = {}
  -- Context: common prefix (show up to 3 lines before the change).
  local ctx_start = math.max(1, prefix_len - 2)
  for i = ctx_start, prefix_len do
    table.insert(numbered, string.format("%5d  %s", i, " " .. after_lines[i]))
  end

  -- Deletions (old lines between prefix and suffix).
  for i = prefix_len + 1, #before_lines - suffix_len do
    table.insert(numbered, string.format("%5d  %s", i, "-" .. before_lines[i]))
  end

  -- Additions (new lines between prefix and suffix).
  for i = prefix_len + 1, #after_lines - suffix_len do
    table.insert(numbered, string.format("%5d  %s", i, "+" .. after_lines[i]))
  end

  -- Context: common suffix (show up to 3 lines after the change).
  local ctx_end = math.min(3, suffix_len)
  for i = 1, ctx_end do
    local new_idx = #after_lines - suffix_len + i
    table.insert(numbered, string.format("%5d  %s", new_idx, " " .. after_lines[new_idx]))
  end

  return numbered
end

return M
