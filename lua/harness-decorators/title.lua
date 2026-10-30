-- Shared harness title colors and hl-group helpers.
local utils = require("harness-decorators.utils")

local M = {}

---A harness's title color from its adapter's title_color, or nil for a name that is not a
---harness. A real harness's adapter is required unguarded, so its load error surfaces.
---@param name string
---@return string?
local function color_for(name)
  if not vim.tbl_contains(utils.list_harnesses(), name) then
    return nil
  end
  return require("harness-decorators." .. name).title_color
end

---Define the HarnessTitle<Name> hl group for a harness. Uses `default` so a
---later ColorScheme change can still override it, while a plain link would be
---clobbered by any scheme that links its own groups to Normal.
function M.define(name)
  local color = color_for(name)
  if not color then
    return nil
  end
  local group = "HarnessTitle" .. utils.capitalize(name)
  vim.api.nvim_set_hl(0, group, { default = true, fg = color })
  return group
end

---Return a snacks.win title value (string or segment list) for a harness.
function M.title(name)
  local text = " " .. utils.capitalize(name) .. " "
  local group = M.define(name)
  if not group then
    return text
  end
  return { { text, group } }
end

---The picker's "(not installed)" suffix group: dim so uninstalled harnesses recede visually.
M.picker_not_installed_group = "HarnessPickerNotInstalled"

---Define groups for all known harnesses (used at LazyDone and on ColorScheme).
function M.define_all()
  for _, name in ipairs(utils.list_harnesses()) do
    M.define(name)
  end
  vim.api.nvim_set_hl(0, M.picker_not_installed_group, { default = true, fg = "#5b6270" })
  -- Dim the telescope selected-row highlight: nord's TelescopeSelection has a
  -- bright bg and an fg that overrides the per-entry harness color on the
  -- selected row (its extmark priority 4096 beats our entry highlights at 200).
  -- Linking to Visual gives a dim bg with no fg, so the colored harness text
  -- shows through. A plain nvim_set_hl here would be ignored because the group
  -- already has a non-default definition from the colorscheme; a link replaces it.
  vim.cmd("highlight! link TelescopeSelection Visual")
end

return M
