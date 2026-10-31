-- Pi harness adapter (pi.dev / @earendil-works/pi-coding-agent). Implements the generic adapter
-- interface (docs/ai/agents/adapter-structure.md) so the harness-agnostic modules (watcher,
-- jsonl-parser) can load it while pi is the active harness.
--
-- Context keymaps (<leader>ca / <C-t> / visual <leader>ca / <leader>cc / <leader>cr) are
-- wired in pi/keymaps.lua.
--
-- Edits and session state arrive from the pi extension; see pi/follow.lua.
--
-- The remaining adapter functions are inherited from the shared stub base (stub-adapter.lua)
-- and are never reached while projects_dir() is nil.
local stub = require("harness-decorators.stub-adapter")

local M = setmetatable({}, { __index = stub })

---Title color: white (pi.dev logo).
M.title_color = "#ffffff"

-- The pi extension pushes edit events into nvim, so the filesystem watcher stays off for pi.
M.push_following = true

-- ==========================================================================
-- PATHS
-- ==========================================================================

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
  return stub.NO_DIFF
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
