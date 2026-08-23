-- Maki harness adapter. Implements the same interface as
-- harness-decorators.claude (see docs/ai/agents/adapter-structure.md) so the
-- generic modules (watcher, jsonl-parser) are harness-agnostic.
--
-- Status: session identification works (the watcher pins the right session and
-- the statusline shows it). Edit parsing is STUBBED - maki's JSONL dialect is
-- not implemented yet, so no notifications or jumps fire for maki edits. The
-- setup warning in harness-decorators.init tells the user this.
local utils = require("harness-decorators.utils")

local M = {}

---True when this Neovim session runs under the maki harness.
function M.is_active()
  return utils.harness == "maki"
end

-- ==========================================================================
-- PATHS
-- ==========================================================================

---Directory containing maki's session JSONLs and cwd_latest.json. Mirrors
---maki's own state dir resolution (maki-storage/src/paths.rs): if ~/.maki
---exists it IS the state dir, otherwise XDG_STATE_HOME/maki. Old and new
---locations can coexist, so check both.
---@return string?
function M.sessions_dir()
  local home = os.getenv("HOME") or ""
  local xdg_state = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
  local candidates = {
    home .. "/.maki/sessions",
    xdg_state .. "/maki/sessions",
  }
  for _, dir in ipairs(candidates) do
    if vim.uv.fs_stat(dir) then
      return dir
    end
  end
  return nil
end

---Alias for the generic adapter interface: the directory to watch.
---@return string?
function M.projects_dir()
  return M.sessions_dir()
end

---Maki's session JSONLs live at the top level of the sessions dir (no
---per-project subdirs), so fswatch should watch the dir itself, non-recursively.
M.flat_sessions_dir = true

---Maki writes a cwd -> session-id map next to its session JSONLs. Returns the
---session ID for `cwd`, or nil if the file is missing/unreadable.
---@param cwd string
---@return string?
function M.session_for_cwd(cwd)
  local dir = M.sessions_dir()
  if not dir then
    return nil
  end
  local f = io.open(dir .. "/cwd_latest.json", "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  local ok, map = pcall(vim.json.decode, content)
  if ok and type(map) == "table" and map[cwd] then
    return map[cwd]
  end
  return nil
end

-- ==========================================================================
-- SESSION IDENTIFICATION
-- ==========================================================================

---Read the cwd from the header line at the TOP of a maki session file.
---@param jsonl_path string?
---@return string?
function M.read_header_cwd(jsonl_path)
  if not jsonl_path then
    return nil
  end
  local f = io.open(jsonl_path, "r")
  if not f then
    return nil
  end
  local first = f:read("*l")
  f:close()
  if not first then
    return nil
  end
  local ok, entry = pcall(vim.json.decode, first)
  if ok and entry and entry.t == "header" and entry.cwd then
    return entry.cwd
  end
  return nil
end

---Extract the session's cwd from maki JSONL lines, falling back to the header
---line at the TOP of the file (a tail-only scan never sees it).
---@param lines string[]
---@return string?
function M.extract_cwd(lines)
  for _, line in ipairs(lines) do
    if line:find('"cwd"') then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and entry and entry.t == "header" and entry.cwd then
        return entry.cwd
      end
    end
  end
  return nil
end

---Determine whether a JSONL session belongs to this Neovim instance.
---Returns "match", "mismatch", or "unknown".
---Maki: the header line at the top of the file carries the session's cwd. If it
---matches this nvim's cwd, the session is ours by definition (works even when
---the tail has no typed messages). A corrupted/unreadable header falls through
---to "unknown" so a later write can retry.
---@param nvim_cwd string? CWD of this Neovim instance (nil = unknown)
---@param lines string[] JSONL lines to inspect
---@param jsonl_path string? Full path of the session JSONL
---@return "match"|"mismatch"|"unknown"
function M.session_ownership(nvim_cwd, lines, jsonl_path)
  if nvim_cwd then
    local cwd = M.extract_cwd(lines) or M.read_header_cwd(jsonl_path)
    if cwd and cwd ~= nvim_cwd then
      return "mismatch"
    end
    if cwd == nvim_cwd then
      return "match"
    end
  end
  return "unknown"
end

---True when a reset command keeps the SAME jsonl file (only history is wiped).
---/compact rewrites the same JSONL (archiving old turns); /new switches to a
---different one. Maki has no /clear.
---@param cmd string The reset command text (e.g. "/compact")
---@return boolean
function M.is_same_file_reset(cmd)
  return cmd == "/compact"
end

-- ==========================================================================
-- RESET DETECTION (STUB)
-- ==========================================================================

---Scan maki JSONL lines for a session-resetting user command. Returns the
---command text ("/new" or "/compact") or nil.
---TODO(maki): implement - detect /new and /compact typed messages so session
---state can be cleared on reset. Not needed for basic pinning.
---@param lines string[]
---@return string?
function M.find_reset_command(_lines)
  return nil
end

-- ==========================================================================
-- TOOL RESULT PARSING (STUB)
-- ==========================================================================

---Parse a maki JSONL line for file changes. Returns the normalized change_info
---table or nil.
---TODO(maki): implement - maki's edit/multiedit/write tool results carry a
---full-file Diff (d.Diff = {path, before, after}); derive file_path and
---starting_line from it so notifications can fire. Until then the watcher
---pins the session but reports no edits.
---@param line string The JSONL line text
---@param line_number? integer The 1-based line number in the JSONL file
function M.parse_tool_result(_line, _line_number)
  return nil
end

return M
