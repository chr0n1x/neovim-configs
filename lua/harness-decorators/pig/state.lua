-- Pig state adapter: session label and working/idle from ~/.pig/agent/sessions (pig never reads
-- ~/.pi). Status comes from the session file's last message, not the child check: pig keeps its
-- extension runtime (a node process) as a child the whole time it runs. See pi-session-state.lua.
return require("harness-decorators.pi-session-state").new({
  harness = "pig",
  config_dir = ".pig",
  turn_status = true,
})
