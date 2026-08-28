-- Shared harness title colors and hl-group helpers.
-- Colors match tmux/scripts/tmux-agent-pick.sh (agent_color).
local M = {}

M.colors = {
  claude = "#f0965f", -- light rust
  maki = "#6eb9f0", -- light cerulean
  copilot = "#aa78ff", -- purple
}

---Define the HarnessTitle<Name> hl group for a harness.
function M.define(name)
  local color = M.colors[name]
  if not color then
    return nil
  end
  local group = "HarnessTitle" .. name:sub(1, 1):upper() .. name:sub(2)
  vim.api.nvim_set_hl(0, group, { fg = color })
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
end

return M
