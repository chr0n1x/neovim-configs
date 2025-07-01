return {
  {
    'sindrets/diffview.nvim',
    keys = {
      { '<leader>D', ':DiffviewFileHistory %<CR>', desc = 'Diffview: open.' },
      { '<leader>d', ':DiffviewOpen<CR>', desc = 'Diffview: open.' },
      { '<leader>dr', ':DiffviewRefresh<CR>', desc = 'Diffview: refresh.' },
      { '<leader>d<enter>', ':DiffviewClose<CR>', desc = 'Diffview: close.' },
    },
    config = function()
      vim.api.nvim_set_hl(0, 'DiffAdd', { 'DiffDelete' })
      vim.api.nvim_set_hl(0, 'DiffDelete', { 'DiffAdd' })
    end,
  },

  {
    'mrloop/telescope-git-branch.nvim',
    config = function ()
      vim.keymap.set('n', '<leader>df', require('git_branch').files , { desc = 'Telescope: Show git diff.' })
    end
  }
}
