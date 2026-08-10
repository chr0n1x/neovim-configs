-- Detect whether java is available on PATH (no JVM startup).
local handle = io.popen("which java 2>/dev/null")
local java_path = handle and handle:read("*a")
if handle then
  handle:close()
end
if not java_path or java_path == "" then
  return {}
end

-- Detect whether debugjava is available on PATH.
local debug_handle = io.popen("which debugjava 2>/dev/null")
local debugjava_path = debug_handle and debug_handle:read("*a")
if debug_handle then
  debug_handle:close()
end

local deps = {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    setup = function()
      vim.lsp.config("jdtls", {
        settings = {
          java = {
            -- Custom eclipse.jdt.ls options go here
          },
        },
      })
      vim.lsp.enable("jdtls")
    end,
  },
}

if debugjava_path and debugjava_path ~= "" then
  table.insert(deps, {
    "rcarriga/nvim-dap-ui",
    dependencies = {
      "mfussenegger/nvim-dap",
      "nvim-neotest/nvim-nio",
    },
  })
end

return deps
