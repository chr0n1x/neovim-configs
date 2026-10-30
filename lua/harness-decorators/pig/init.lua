-- Pig harness adapter (pig: the Go wrapper around Pi, config in ~/.pig). Implements the generic
-- adapter interface on the shared stub base so the harness-agnostic modules (watcher,
-- jsonl-parser) can require it when pig is the active harness.
--
-- projects_dir() is nil, so the JSONL watcher stays off and pig edits are not auto-followed.
-- Context keymaps live in pig/keymaps.lua; status + session label in pig/state.lua.
local M = setmetatable({}, { __index = require("harness-decorators.stub-adapter") })

---Title color: green, same as the idle checkmark (agent-display AgentDotIdle).
M.title_color = "#3ddc6e"

return M
