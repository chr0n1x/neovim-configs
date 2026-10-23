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
  config = function(_, opts)
    require("zen-mode").setup(opts)
    -- Reopen zen mode when focus returns after a tmux pane switch.
    -- Zen-mode's WinEnter autocmd closes zen when focus was in a non-float
    -- window; FocusGained catches the return trip and reopens.
    vim.api.nvim_create_autocmd("FocusGained", {
      group = vim.api.nvim_create_augroup("ZenTmuxNav", { clear = true }),
      callback = function()
        local ok, view = pcall(require, "zen-mode.view")
        if not ok then
          return
        end
        -- If zen is closed but its parent window is still alive, the close
        -- was caused by the WinEnter timer (tmux pane switch), not a user
        -- toggle. Reopen.
        if not view.is_open() and view.parent and vim.api.nvim_win_is_valid(view.parent) then
          vim.schedule(function()
            pcall(require("zen-mode").open)
          end)
        end
      end,
    })
  end,
  keys = {
    { "<leader>z", "<cmd>ZenMode<cr>", desc = "Toggle Zen Mode" },
  },
}
