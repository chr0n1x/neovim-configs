-- Maki state adapter: work status + session label.
--
-- Status: maki has no per-pid status file, so this returns "unknown" and lets
-- agent-state run the shared child check. Tool/bash execution shows as working;
-- pure text generation does not.
--
-- Label: ~/.maki/sessions/cwd_latest.json maps cwd to the session id of the most
-- recent session started in that dir; the label is the last "t":"meta" line's
-- title in <sid>.jsonl (the header carries the title too, but meta lines are
-- re-written as the session evolves).

local utils = require("harness-decorators.utils")

local M = {}

local function sessions_dir()
  return require("harness-decorators.maki").sessions_dir()
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, _cwd)
  -- No per-pid signal; delegate to the child-process check.
  return "unknown"
end

---Last meta title in a session jsonl.
---@param path string
---@return string?
local function read_meta_title(path, inputs)
  if inputs then
    inputs.label_cacheable = false
  end
  return utils.read_tail_lines(path, 256 * 1024, function(line)
    if inputs then
      inputs.label_cacheable = true
    end
    if line:find('"t":"meta"', 1, true) or line:find('"t": "meta"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" and type(entry.title) == "string" and entry.title ~= "" then
        return entry.title
      end
    end
    return nil
  end)
end

---Header of a session jsonl: the first line carries id + created_at (unix). Returns the
---decoded table or nil.
---@param path string
---@return table?
local function read_header(path)
  return utils.read_first_line_table(path)
end

---The session jsonl in `dir` whose header created_at best matches the terminal's open
---time (see utils.pick_jsonl_by_time). nil when nothing is close enough.
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

local function session_file(cwd)
  local dir = sessions_dir()
  if not dir or not cwd or cwd == "" then
    return nil
  end
  -- Prefer the session matching this terminal's open time; opened_at is nil outside term
  -- (tests), which falls through to cwd_latest.
  local ok_term, term = pcall(require, "harness-decorators.term")
  if ok_term and type(term.opened_at) == "function" then
    local live = session_for_open(dir, term.opened_at("maki"), cwd)
    if live then
      return live
    end
  end
  -- Fallback: cwd_latest.json { [cwd] = session_id } (lazy-updated, so it can lag a fresh open).
  local map = utils.read_json_file(dir .. "/cwd_latest.json")
  if not map then
    return nil
  end
  local sid = map[cwd]
  if type(sid) ~= "string" or sid == "" then
    return nil
  end
  return dir .. "/" .. sid .. ".jsonl"
end

function M.inputs(_pid, cwd)
  local path = session_file(cwd)
  return { path = path, label_key = path, label_paths = { path } }
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(pid, cwd, inputs)
  local path = (inputs or M.inputs(pid, cwd)).path
  return path and read_meta_title(path, inputs) or nil
end

return M
