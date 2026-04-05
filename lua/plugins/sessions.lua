return {
  {
    lazy = false,
    'jedrzejboczar/possession.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim'
    },
    opts = {
      autoload = 'auto_cwd',
      autosave = {
        cwd = true,
        current = true,
        on_load = true,
        on_quit = true,
      },
      plugins = {
        close_windows = {
          hooks = { 'before_save', 'before_load' },
          preserve_layout = true,
          match = {
            floating = false,
            buftype = {},
            filetype = {},
          },
        },
        delete_hidden_buffers = {
          hooks = {
            'before_load',
            vim.o.sessionoptions:match('buffer') and 'before_save',
          },
          force = true,
        },
      },
    },
    keys = {
      { '<leader>sl', '<cmd>PossessionListCwd<cr>', desc = '📌 Show cwd session.' },
      { '<leader>ss', '<cmd>PossessionSave<cr>', desc = '📌 Save current session' },
    },
  },
}
