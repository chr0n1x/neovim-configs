-- Pi state adapter: work status + session label from ~/.pi/agent/sessions, preferring the session
-- events the pi extension pushes into pi/follow.lua. See pi-session-state.lua.
return require("harness-decorators.pi-session-state").new({
  harness = "pi",
  config_dir = ".pi",
  follow = "harness-decorators.pi.follow",
})
