require('telescope').setup{
  defaults = {
    file_ignore_patterns = {
      "node_modules",
      ".git"
    }
  }
}

require('nvim-treesitter.configs').setup {
  ensure_installed = {'vim', 'lua', 'bash', 'yaml', 'json', 'hcl', 'make', 'go' },
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = true,
    use_languagetree = true
  },
  indent = {
    enable = true
  }
}
