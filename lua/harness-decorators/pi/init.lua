-- Pi harness adapter (pi.dev / @earendil-works/pi-coding-agent). Implements the
-- generic adapter interface (see docs/ai/agents/adapter-structure.md) so the
-- harness-agnostic modules (watcher, jsonl-parser) can require it without
-- crashing when pi is the active harness.
--
-- Context keymaps (<leader>ca / <C-t> / visual <leader>ca / <leader>cc / <leader>cr) are
-- wired in pi/keymaps.lua.
--
-- Edit-following AND session state: pi does NOT use the JSONL watcher other harnesses use.
-- projects_dir() stays nil (watcher off). Instead a pi EXTENSION (nvim-harness-follow.ts) runs
-- inside pi and pushes two kinds of events to this nvim over $NVIM:
--   * edit events    -> fire the `User HarnessEdit` autocmd edit-jump.lua consumes (jump to file:line)
--   * session events -> real session id + working/idle status, which pi/state.lua reads for accurate
--                       status + a uuid label instead of guessing from file mtimes.
-- This avoids reverse-engineering pi's JSONL record shape, session pinning, and fswatch - pi hands
-- us structured data (path + numbered details.diff, getSessionId(), agent_start/settled) directly.
-- See pi/follow.lua for the nvim-side bridge (symlink bootstrap + RPC receiver + registry) and
-- nvim-harness-follow.ts for the pi-side push.
--
-- on_activate() (called by the generic adapter hook in init.setup and switch.switch) is what
-- makes the extension portable: it symlinks the repo's extension file into pi's global
-- extensions dir, so shipping the nvim config ships pi edit-following with no manual install.
--
-- The remaining adapter functions are inherited from the shared stub base (stub-adapter.lua)
-- and are never reached while projects_dir() is nil.
local M = setmetatable({}, { __index = require("harness-decorators.stub-adapter") })

-- The pi extension pushes structured edit events into Neovim, so the generic filesystem watcher
-- must not warn or attempt to start for this adapter.
M.push_following = true

-- ==========================================================================
-- PATHS
-- ==========================================================================

---nil keeps the JSONL watcher off for pi: edit-following is push-based via the extension
---(see pi/follow.lua), not tail-based.
---@return string?
function M.projects_dir()
  return nil
end

---Extract pi's UUID from its timestamp_UUID session filename.
---@param jsonl_path string
---@return string?
function M.session_id(jsonl_path)
  return jsonl_path:match("_([%x%-]+)%.jsonl$")
end

---Name the sidecar used by the pi push bridge.
---@param session_id string
---@return string
function M.sidecar_name(session_id)
  return "pi-events-session-" .. session_id
end

---Score a synthetic event written by pi/follow.lua.
---@param ev table
---@return integer
function M.score_event(ev)
  return ev.type == "pi_harness_edit" and type(ev.diff) == "string" and 3 or 0
end

---Return pi's already-numbered edit diff for the history preview.
---@param ev table?
---@return string
function M.extract_diff(ev)
  if ev and type(ev.diff) == "string" and ev.diff ~= "" then
    return ev.diff
  end
  return "(no diff data available)"
end

-- ==========================================================================
-- ACTIVATION
-- ==========================================================================

---Run when pi becomes the active harness (init.setup at startup, or switch.switch). Ensures
---the pi edit-following extension is symlinked into pi's global extensions dir so the next pi
---launch loads it. Idempotent and fail-soft.
function M.on_activate()
  pcall(function()
    require("harness-decorators.pi.follow").ensure()
  end)
end

return M
