-- Pi harness (pi.dev / @earendil-works/pi-coding-agent): per-key entries for the
-- consolidated <leader>c* keymap table in lua/plugins/ai-harness.lua. Each entry
-- is a lazy.nvim key spec (lhs, action, desc, mode/ft).
--
-- Barebones on purpose (matches the crush setup). pi does support @file mentions
-- and writes JSONL sessions, so live edit-following is feasible later, but this
-- scope wires up only open/focus and continue. `--continue` is pi's own flag
-- (pi --help: "--continue, -c  Continue previous session"). See pi/init.lua.
local keymaps = require("harness-decorators.keymaps")

return {
  -- <leader>c is wired by keymaps.build() from focus_spec, which triggers the JSONL
  -- watcher; this file does not declare it.
  -- <leader>cc: continue the last session via OUR per-harness float (term.lua), not a claudecode cmd.
  keymaps.continue_spec("pi"),
}
