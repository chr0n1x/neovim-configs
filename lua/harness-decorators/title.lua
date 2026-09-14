-- Shared harness title colors and hl-group helpers.
-- Colors match tmux/scripts/tmux-agent-pick.sh (agent_color).
local M = {}

-- Per-harness title colors (private; only used by the helpers below). Match
-- tmux/scripts/tmux-agent-pick.sh (agent_color).
local colors = {
  claude = "#f0965f", -- light rust
  maki = "#6eb9f0", -- light cerulean
  copilot = "#aa78ff", -- purple
  crush = "#ff60ff", -- charm magenta
  pi = "#ffffff", -- white (pi.dev logo)
}

---Define the HarnessTitle<Name> hl group for a harness. Uses `default` so a
---later ColorScheme change can still override it, while a plain link would be
---clobbered by any scheme that links its own groups to Normal.
function M.define(name)
  local color = colors[name]
  if not color then
    return nil
  end
  local group = "HarnessTitle" .. name:sub(1, 1):upper() .. name:sub(2)
  vim.api.nvim_set_hl(0, group, { default = true, fg = color })
  return group
end

---Return a snacks.win title value (string or segment list) for a harness.
function M.title(name)
  local text = " " .. name:sub(1, 1):upper() .. name:sub(2) .. " "
  local group = M.define(name)
  if not group then
    return text
  end
  return { { text, group } }
end

---The picker's state-glyph colors (Task 9): a filled circle for the active harness, a hollow one
-- for a parked (backgrounded, still-running) harness. Defined with `default` so a later ColorScheme
-- can override them; distinct from the per-harness title groups because they describe STATE, not
-- which CLI is running. Exposed on M so tests/picker_spec.lua can assert the group names.
M.picker_glyphs = {
  active = { group = "HarnessPickerActive", fg = "#a3be8c" }, -- green: this one is in front
  parked = { group = "HarnessPickerParked", fg = "#81a1c1" }, -- blue: running in the background
}

---The picker's "(not installed)" suffix group: dim so uninstalled harnesses recede visually.
M.picker_not_installed_group = "HarnessPickerNotInstalled"

---Define the picker state-glyph groups (active / parked) + the not-installed dim group. Called from
--M.define_all.
function M.define_picker_glyphs()
  for _, spec in pairs(M.picker_glyphs) do
    vim.api.nvim_set_hl(0, spec.group, { default = true, fg = spec.fg })
  end
  vim.api.nvim_set_hl(0, M.picker_not_installed_group, { default = true, fg = "#5b6270" })
end

---Define groups for all known harnesses (used at LazyDone and on ColorScheme).
function M.define_all()
  for name in pairs(colors) do
    M.define(name)
  end
  M.define_picker_glyphs()
  -- Dim the telescope selected-row highlight: nord's TelescopeSelection has a
  -- bright bg and an fg that overrides the per-entry harness color on the
  -- selected row (its extmark priority 4096 beats our entry highlights at 200).
  -- Linking to Visual gives a dim bg with no fg, so the colored harness text
  -- shows through. A plain nvim_set_hl here would be ignored because the group
  -- already has a non-default definition from the colorscheme; a link replaces it.
  vim.cmd("highlight! link TelescopeSelection Visual")
end

return M
