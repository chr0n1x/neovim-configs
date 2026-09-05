-- Shared harness title colors and hl-group helpers.
-- Colors match tmux/scripts/tmux-agent-pick.sh (agent_color).
local M = {}

M.colors = {
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
  local color = M.colors[name]
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

---Define groups for all known harnesses (used at LazyDone and on ColorScheme).
function M.define_all()
  for name in pairs(M.colors) do
    M.define(name)
  end
  -- Dim the telescope selected-row highlight: nord's TelescopeSelection has a
  -- bright bg and an fg that overrides the per-entry harness color on the
  -- selected row (its extmark priority 4096 beats our entry highlights at 200).
  -- Linking to Visual gives a dim bg with no fg, so the colored harness text
  -- shows through. A plain nvim_set_hl here would be ignored because the group
  -- already has a non-default definition from the colorscheme; a link replaces it.
  vim.cmd("highlight! link TelescopeSelection Visual")
end

return M
