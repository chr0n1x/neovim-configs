-- Sidecar event log: mirrors pinned session JSONL lines to a per-nvim file.
local utils = require("harness-decorators.utils")
local M = {}

---Directory holding sidecars and the watcher's log and pidfile, shared by every nvim instance.
---@return string
function M.dir()
  return vim.fn.stdpath("cache") .. "/harness"
end

---Create `dir` owner-only (sidecars hold code from the sessions).
---@param dir string
---@return boolean ok
local function make_dir(dir)
  if vim.fn.isdirectory(dir) == 1 then
    return true
  end
  local ok, err = pcall(vim.fn.mkdir, dir, "p", tonumber("700", 8))
  if not ok or vim.fn.isdirectory(dir) == 0 then
    utils.log("cannot create sidecar dir " .. dir .. ": " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

---Remove this nvim's sidecars on VimLeave, which runs after every VimLeavePre handler, so
---edits delivered while init.lua's shutdown waits for the harnesses and the watcher are removed too.
local function register_exit_cleanup()
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "HarnessSidecarCleanup", event = "VimLeave" })
  if ok and #cmds > 0 then
    return
  end
  vim.api.nvim_create_autocmd("VimLeave", {
    group = vim.api.nvim_create_augroup("HarnessSidecarCleanup", { clear = true }),
    callback = function()
      M.remove_instance(vim.fn.getpid())
    end,
  })
end

---Create M.dir() and return it.
---@return string
function M.ensure_dir()
  local dir = M.dir()
  make_dir(dir)
  register_exit_cleanup()
  return dir
end

---Derive the sidecar file path from a session ID.
---The filename is harness-specific; each adapter provides `sidecar_name()`.
---Format: <M.dir()>/<nvim pid>-<harness-sidecar-name>.jsonl
---@param session_id string
---@return string
function M.path(session_id)
  local adapter = require("harness-decorators." .. utils.harness)
  local name = adapter.sidecar_name(session_id)
  return string.format("%s/%d-%s.jsonl", M.dir(), vim.fn.getpid(), name)
end

---Remove every sidecar written by the nvim with this pid, by exact file name.
---@param nvim_pid integer
function M.remove_instance(nvim_pid)
  for _, file in ipairs(vim.fn.glob(string.format("%s/%d-*.jsonl", M.dir(), nvim_pid), true, true)) do
    os.remove(file)
  end
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

---Append a raw JSONL line to the sidecar file. Best effort: a directory or file that cannot be
---written is logged and the line is dropped.
---@param sidecar_path string
---@param raw_line string
function M.append(sidecar_path, raw_line)
  if not sidecar_path then
    return
  end
  local dir = sidecar_path:match("(.*)/[^/]+$")
  if dir and not make_dir(dir) then
    return
  end
  register_exit_cleanup()
  local f, err = io.open(sidecar_path, "a")
  if not f then
    utils.log("cannot write sidecar " .. sidecar_path .. ": " .. tostring(err), vim.log.levels.WARN)
    return
  end
  f:write(raw_line, "\n")
  f:close()
end

---Look up the best event from a sidecar file matching uuid + timestamp (+ optional id).
---Substring pre-filter before decoding.
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
