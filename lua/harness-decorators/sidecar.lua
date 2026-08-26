-- Sidecar event log: mirrors pinned session JSONL lines to a per-nvim file.
local utils = require("harness-decorators.utils")
local M = {}

---Get the USER env var, warn and return "unknown-user" if not set.
local function get_user()
  local user = os.getenv("USER")
  if not user then
    utils.log("USER env var not set, using 'unknown-user'", vim.log.levels.WARN)
    return "unknown-user"
  end
  return user
end

---Derive the sidecar file path from a session ID.
---The filename is harness-specific; each adapter provides `sidecar_name()`.
---Format: /tmp/nvim.${USER}/${pid}-<harness-sidecar-name>.jsonl
---@param session_id string
---@return string
function M.path(session_id)
  local user = get_user()
  local neovim_pid = tostring(vim.uv.os_getppid())
  local dir = string.format("/tmp/nvim.%s", user)
  local adapter = require("harness-decorators." .. utils.harness)
  local name = adapter.sidecar_name(session_id)
  return string.format("%s/%s-%s.jsonl", dir, neovim_pid, name)
end

---Derive the sidecar file path from a pinned JSONL session path.
---@param jsonl_path string|nil
---@return string|nil
function M.path_from_jsonl(jsonl_path)
  if not jsonl_path then
    return nil
  end
  local session_id = utils.extract_session_id(jsonl_path)
  if not session_id then
    return nil
  end
  return M.path(session_id)
end

---Append a raw JSONL line to the sidecar file.
---@param sidecar_path string
---@param raw_line string
function M.append(sidecar_path, raw_line)
  if not sidecar_path then
    return
  end
  -- Ensure /tmp/nvim.$USER exists.
  local dir = sidecar_path:match("(.*/)[^/]+$")
  if dir then
    vim.uv.fs_mkdir(dir, 493) -- 0755
  end
  local f = io.open(sidecar_path, "a")
  if not f then
    return
  end
  f:write(raw_line, "\n")
  f:close()
end

---Look up the best event from a sidecar file matching uuid + timestamp (+ optional id).
---String matching is used as a fast pre-filter before full JSON decode.
---This avoids decoding every line in the sidecar, which keeps lookup O(n)
---with a very small constant for the majority of non-matching lines.
---The scoring function is harness-specific (adapter `score_event`).
---@param sidecar_path string
---@param uuid string|nil
---@param timestamp any|nil
---@param id string|nil
---@return table|nil
function M.lookup(sidecar_path, uuid, timestamp, id)
  if not sidecar_path then
    return nil
  end
  -- Need at least one identifier to match against.
  if not uuid and not id then
    return nil
  end
  local f = io.open(sidecar_path, "r")
  if not f then
    return nil
  end

  local adapter = require("harness-decorators." .. utils.harness)
  local best = nil
  local best_score = -1
  local ts_str = tostring(timestamp)

  for line in f:lines() do
    -- Match by whatever identifiers are available.
    if uuid and not line:find(uuid, 1, true) then
      goto continue
    end
    if timestamp and not line:find(ts_str, 1, true) then
      goto continue
    end
    if id and not line:find(id, 1, true) then
      goto continue
    end

    local ok, ev = pcall(vim.json.decode, line)
    if ok then
      local s = adapter.score_event(ev)
      if s > best_score then
        best = ev
        best_score = s
      end
    end
    ::continue::
  end
  f:close()
  return best
end

---Extract diff text from a matched sidecar event. Delegates to the active
---adapter's `extract_diff` method, which knows how to render its own dialect.
---@param ev table|nil
---@return string
function M.extract_diff(ev)
  local adapter = require("harness-decorators." .. utils.harness)
  return adapter.extract_diff(ev)
end

return M
