if IN_PERF_MODE then
  return {}
end

return {
  {
    "nvim-telescope/telescope-fzf-native.nvim",
    -- not sure why this doesnt work ootb
    -- have to go into ~/.local/share/nvim/lazy/telescope-fzf-native.nvim/ && make
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
