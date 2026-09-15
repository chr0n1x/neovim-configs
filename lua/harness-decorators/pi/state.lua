-- Pi state adapter: session label (ported from the tmux picker's pi branch).
--
-- Pi has no per-pid status source in the tmux script - it rides the shared
--child-process check - so this adapter only provides a label.
--
-- Label: pi keys its session dir off the cwd: --<cwd>-- with the leading slash
--stripped and /, \, : turned into - (jsonlSessionDirectoryName in the pi
--bundle). macOS won't expose a process's env, so the exact PI_SESSION_FILE
--isn't reachable by pid; instead take the most recently modified session file
--in that dir (matches maki's cwd-latest behaviour). The label is the last
--session_info.name (user/auto title), else the first user message.

local utils = require("harness-decorators.utils")

local M = {}

local function sessions_root()
  return (os.getenv("HOME") or "") .. "/.pi/agent/sessions"
end

---cwd -> pi session dir name (ported from the sed in the tmux script).
---@param cwd string
---@return string
local function dir_name(cwd)
  local s = cwd:match("^/(.*)$") or cwd
  s = s:gsub("/", "-"):gsub("\\", "-"):gsub(":", "-")
  return "--" .. s .. "--"
end

---The *.jsonl in `dir` whose mtime best matches the terminal's open time. A fresh session started
--in a dir that already has older ones must NOT be labelled with the previous one, so we match by
--open time rather than "newest file". Returns the path, or nil when nothing is close enough (caller
--falls back to newest_jsonl).
---@param dir string
---@param opened_at number? unix time this terminal instance was opened
---@return string?
local function jsonl_for_open(dir, opened_at)
  -- Tolerance: the file's first write lands within a second or two of snacks.open.
  return utils.pick_jsonl_by_time(dir, opened_at, 30, function(path)
    local st = vim.uv.fs_stat(path)
    return st and st.mtime.sec
  end)
end

---Most recently modified *.jsonl in a dir (ls -t | head -1 equivalent). Fallback when no session's
--mtime matches the terminal's open time.
---@param dir string
---@return string?
local function newest_jsonl(dir)
  local d = vim.uv.fs_opendir(dir)
  if not d then
    return nil
  end
  local best, best_m = nil, -1
  while true do
    local r = vim.uv.fs_readdir(d)
    if not r or type(r) ~= "table" or #r == 0 then
      break
    end
    local e = r[1]
    if not e or not e.name then
      break
    end
    if e.name:match("%.jsonl$") then
      local st = vim.uv.fs_stat(dir .. "/" .. e.name)
      local m = st and st.mtime.sec or -1
      if m > best_m then
        best, best_m = dir .. "/" .. e.name, m
      end
    end
  end
  vim.uv.fs_closedir(d)
  return best
end

---Last session_info.name, else first user message (ported from the python).
---@param path string
---@return string?
local function read_title(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local name, first = nil, nil
  for line in f:lines() do
    local ok, e = pcall(vim.json.decode, line)
    if not ok or type(e) ~= "table" then
      goto continue
    end
    if e.type == "session_info" and type(e.name) == "string" and e.name ~= "" then
      name = e.name
    elseif not first and e.type == "message" then
      local m = e.message
      if type(m) == "table" and m.role == "user" then
        local c = m.content
        if type(c) == "table" then
          local parts = {}
          for _, b in ipairs(c) do
            if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
              parts[#parts + 1] = b.text
            end
          end
          c = table.concat(parts, " ")
        end
        if type(c) == "string" and c ~= "" then
          first = c:gsub("\n", " "):match("^%s*(.-)%s*$")
        end
      end
    end
    ::continue::
  end
  f:close()
  return name or first
end

---@param pid number|string
---@param cwd string
---@return "working"|"idle"|"unknown"
function M.status(_pid, _cwd)
  -- No per-pid signal; delegate to the child-process check.
  return "unknown"
end

---@param pid number|string
---@param cwd string
---@return string?
function M.label(_pid, cwd)
  if not cwd or cwd == "" then
    return nil
  end
  local dir = sessions_root() .. "/" .. dir_name(cwd)
  if not vim.uv.fs_stat(dir) then
    return nil
  end
  -- Prefer the session whose mtime matches THIS terminal's open time (a fresh session in a dir with
  -- older ones must not inherit the previous title). term.opened_at is nil for non-term contexts/
  -- tests, which falls through to newest_jsonl.
  local f = nil
  local ok_term, term = pcall(require, "harness-decorators.term")
  if ok_term and type(term.opened_at) == "function" then
    f = jsonl_for_open(dir, term.opened_at("pi"))
  end
  if not f then
    f = newest_jsonl(dir)
  end
  if not f then
    return nil
  end
  return read_title(f)
end

return M
