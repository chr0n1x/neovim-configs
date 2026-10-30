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

    -- Requiring zen-mode.view can trigger lazy.nvim to load this plugin, and this
    -- config then runs mid-require with its own copy of the module. Look the module
    -- up at call time so every caller shares the same state.
    local function view()
      return require("zen-mode.view")
    end

    local function is_float(win)
      return vim.api.nvim_win_get_config(win).relative ~= ""
    end

    -- zen-mode wraps whatever window is current when it opens. When focus is in a
    -- harness float, move to a normal window first: zen's last parent, else the
    -- harness focus target, else the first normal file window in the tab.
    local function focus_normal_win()
      if not is_float(vim.api.nvim_get_current_win()) then
        return
      end
      local candidates = { view().parent or false, require("harness-decorators.focus").last_win or false }
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
          candidates[#candidates + 1] = w
        end
      end
      for _, w in ipairs(candidates) do
        if w and vim.api.nvim_win_is_valid(w) and not is_float(w) then
          vim.api.nvim_set_current_win(w)
          return
        end
      end
    end

    -- :ZenMode is the user toggle (<leader>z runs it). Clearing view.parent on a
    -- user close tells the FocusGained handler below not to reopen; zen-mode's own
    -- WinEnter auto-close leaves parent set.
    vim.api.nvim_create_user_command("ZenMode", function()
      local v = view()
      if v.is_open() then
        v.close()
        v.parent = nil
      else
        focus_normal_win()
        v.open()
      end
    end, { bar = true, force = true })

    -- Reopen zen mode when focus returns after a tmux pane switch.
    -- Zen-mode's WinEnter autocmd closes zen when focus was in a non-float
    -- window; FocusGained catches the return trip and reopens.
    vim.api.nvim_create_autocmd("FocusGained", {
      group = vim.api.nvim_create_augroup("ZenTmuxNav", { clear = true }),
      callback = function()
        local v = view()
        if not v.is_open() and v.parent and vim.api.nvim_win_is_valid(v.parent) then
          vim.schedule(function()
            if v.parent and vim.api.nvim_win_is_valid(v.parent) then
              pcall(vim.api.nvim_set_current_win, v.parent)
            end
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
