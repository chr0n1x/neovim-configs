local nmap = vim.api.nvim_set_keymap

nmap('n', '<leader><tab>', ':Neotree toggle<CR>', {noremap = true, desc = 'Neotree toggle.' })
nmap('n', '<leader><S-tab>', ':Neotree reveal<CR>', {noremap = true, desc = 'Neotree reveal file for buff.' })

require("neo-tree").setup({
  enable_diagnostics = false,
  window = {
    -- I hate this thing with a passion
    mappings = {
      ['/'] = 'noop',
      ['s'] = 'noop'
    }
  }
})
