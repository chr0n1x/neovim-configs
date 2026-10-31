if IN_PERF_MODE then
  return {}
end

return {
  {
    "nvim-telescope/telescope-fzf-native.nvim",
    -- The native fzf sorter needs compiling. lazy.nvim runs `make` (build) on install and update,
    -- but that has not worked out of the box here; if the sorter is missing, run `make` in
    -- ~/.local/share/nvim/lazy/telescope-fzf-native.nvim/.
    build = "make",
  },

  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    requires = {
      { "windwp/nvim-ts-autotag" },
      { "nvim-treesitter/playground" },
      { "nvim-telescope/telescope-fzf-native.nvim" },
    },
    build = ":TSUpdate",

    opts = {
      highlight = {
        enable = true,
        additional_vim_regex_highlighting = true,
        use_languagetree = true,
      },
      indent = {
        enable = true,
      },
      autotag = { enable = true },
      endwise = { enable = true },
      incremental_selection = {
        enable = true,
        keymaps = {
          init_selection = "<C-space>",
          node_incremental = "<C-space>",
          scope_incremental = false,
          node_decremental = "<bs>",
        },
      },
    },
  },
}
