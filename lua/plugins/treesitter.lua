require('telescope').setup{
  defaults = {
    file_ignore_patterns = {
      "node_modules",
      ".git"
    }
  }
}

require('nvim-treesitter.configs').setup {
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
  },
}
