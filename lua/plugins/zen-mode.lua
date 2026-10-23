if IN_PERF_MODE then
  return {}
end

return {
  "folke/zen-mode.nvim",
  opts = {
    on_open = function(_)
      pcall(function()
        require("harness-decorators.term").set_zen_width(true)
      end)
    end,
    on_close = function()
      pcall(function()
        require("harness-decorators.term").set_zen_width(false)
      end)
    end,
  },
  keys = {
    { "<leader>z", "<cmd>ZenMode<cr>", desc = "Toggle Zen Mode" },
  },
}
