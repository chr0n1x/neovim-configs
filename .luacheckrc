-- Luacheck configuration for Neovim Lua config.
-- Neovim injects globals at runtime so luacheck needs to be told about them.

-- vim and vim.* are runtime-injected — allow any field access.
globals = {
  vim = { any = true },
  IN_PERF_MODE = {},
  DISABLED_IF_IN_PERF_MODE = {},
}

line_max_length = 120
