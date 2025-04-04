return {
  'nvim-treesitter/nvim-treesitter',
  requires = {
    { 'windwp/nvim-ts-autotag' },
    { 'nvim-treesitter/playground' }
  },
  run = ':TSUpdate',
  opts = {
    ensure_installed = {
      'vim', 'lua', 'bash', 'yaml',
      'json', 'hcl', 'make', 'go',
      'typescript', 'markdown',
      'bash', 'ruby'
    },
    highlight = {
      enable = true,
      additional_vim_regex_highlighting = true,
      use_languagetree = true
    },
    indent = {
      enable = true
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
    }
  }
}
