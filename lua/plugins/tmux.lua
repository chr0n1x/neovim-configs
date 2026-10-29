return {
  "alexghergh/nvim-tmux-navigation",
  init = function()
    local nvim_tmux_nav = require("nvim-tmux-navigation")

    -- In zen mode the zen window is a float; wincmd h from a float moves to
    -- the parent window (which closes zen mode) and the plugin sees the window
    -- changed so it skips the tmux call. Bypass the plugin and go straight to
    -- tmux when we're in the zen window.
    local tmux_dirs = { h = "L", j = "D", k = "U", l = "R" }
    local function zen_aware(nav_fn, dir)
      return function()
        if vim.api.nvim_get_current_win() == require("util.zen").win() then
          local tmux_socket = vim.fn.split(vim.env.TMUX, ",")[1]
          vim.fn.system("tmux -S " .. tmux_socket .. " select-pane -" .. tmux_dirs[dir])
          return
        end
        nav_fn()
      end
    end
    vim.keymap.set("n", "<C-h>", zen_aware(nvim_tmux_nav.NvimTmuxNavigateLeft, "h"))
    vim.keymap.set("n", "<C-j>", zen_aware(nvim_tmux_nav.NvimTmuxNavigateDown, "j"))
    vim.keymap.set("n", "<C-k>", zen_aware(nvim_tmux_nav.NvimTmuxNavigateUp, "k"))
    vim.keymap.set("n", "<C-l>", zen_aware(nvim_tmux_nav.NvimTmuxNavigateRight, "l"))
  end,
}
