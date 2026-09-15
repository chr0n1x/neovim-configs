-- Maki state adapter: work status + session label, ported from the tmux picker.
--
-- Status: maki has no per-pid status file (the tmux script's child-process
--check is its only source), so this returns "unknown" and lets agent-state run
--the shared child check. Tool/bash execution shows as working; pure text
--generation does not - a known limitation, same as the tmux picker.
--
-- Label: ~/.maki/sessions/cwd_latest.json maps cwd -> session id of the most
--recent session started in that dir; the label is the last "t":"meta" line's
--title in <sid>.jsonl (the header carries the title too, but meta lines are
--re-written as the session evolves).

local utils = require("harness-decorators.utils")

local M = {}

---Sessions dir resolution mirrors maki/init.lua sessions_dir (check both the
--legacy ~/.maki and XDG locations; they can coexist).
---@return string?
local function sessions_dir()
  local home = os.getenv("HOME") or ""
  local xdg_state = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
  for _, dir in ipairs({ home .. "/.maki/sessions", xdg_state .. "/maki/sessions" }) do
    if vim.uv.fs_stat(dir) then
      return dir
    end
  end
  return nil
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, _cwd)
  -- No per-pid signal; delegate to the child-process check.
  return "unknown"
end

---Last meta title in a session jsonl (grep '"t":"meta"' | tail -1 equivalent).
---@param path string
---@return string?
local function read_meta_title(path)
  return utils.read_tail_lines(path, 256 * 1024, function(line)
    if line:find('"t":"meta"', 1, true) or line:find('"t": "meta"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" and type(entry.title) == "string" and entry.title ~= "" then
        return entry.title
      end
    end
    return nil
  end)
end

---Header of a session jsonl: the first line carries id + created_at (unix). Returns the decoded
--table or nil. Reading only the first line keeps this cheap even for long sessions.
---@param path string
---@return table?
local function read_header(path)
  return utils.read_first_line_table(path)
end

---The session jsonl in `dir` whose header created_at best matches the terminal's open time. A fresh
--session started in a dir that already has older sessions must NOT be labelled with the previous
--one, so we match by open time rather than "newest file". Returns the path, or nil when nothing is
--close enough (caller falls back to cwd_latest).
---@param dir string
---@param opened_at number? unix time this terminal instance was opened
---@param cwd string the terminal's working dir (the header carries it, so we can disambiguate)
---@return string?
local function session_for_open(dir, opened_at, cwd)
  -- Tolerance: the header is written at session start, our os.time() at snacks.open; a few seconds of
  -- skew (clock granularity, slow first write) must not break the match.
  return utils.pick_jsonl_by_time(dir, opened_at, 30, function(path)
    local hdr = read_header(path)
    local created = hdr and tonumber(hdr.created_at)
    -- The sessions dir is shared across every cwd, so a fresh session in one dir must not match a
    -- same-timestamped file from another. Require the header's cwd to agree when it carries one.
    if created and (type(hdr.cwd) ~= "string" or hdr.cwd == "" or hdr.cwd == cwd) then
      return created
    end
    return nil
  end)
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(_pid, cwd)
  local dir = sessions_dir()
  if not dir or not cwd or cwd == "" then
    return nil
  end
  -- Prefer the session that matches THIS terminal's open time (a fresh session in a dir with older
  -- ones must not inherit the previous title). term.opened_at is nil for non-term contexts/tests,
  -- which falls straight through to cwd_latest.
  local ok_term, term = pcall(require, "harness-decorators.term")
  if ok_term and type(term.opened_at) == "function" then
    local live = session_for_open(dir, term.opened_at("maki"), cwd)
    if live then
      return read_meta_title(live)
    end
  end
  -- Fallback: cwd_latest.json { [cwd] = session_id } (lazy-updated, so it can lag a fresh open).
  local f = io.open(dir .. "/cwd_latest.json", "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then
    return nil
  end
  local ok, map = pcall(vim.json.decode, data)
  if not ok or type(map) ~= "table" then
    return nil
  end
  local sid = map[cwd]
  if type(sid) ~= "string" or sid == "" then
    return nil
  end
  return read_meta_title(dir .. "/" .. sid .. ".jsonl")
end

return M
