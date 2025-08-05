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
    "TimUntersberger/neogit",
    cmd = "Neogit",
    config = function()
      require("neogit").setup({
        kind = "split",
        signs = {
          section = { "", "" },
          item = { "", "" },
          hunk = { "", "" },
        },
        integrations = { diffview = true },
      })
    end,
  },

  {
    "lewis6991/gitsigns.nvim",
    event = "BufReadPre",

    config = function()
      require("gitsigns").setup({
        signs = {
          add = { hl = "GitSignsAdd", text = "│", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
          change = {
            hl = "GitSignsChange",
            text = "│",
            numhl = "GitSignsChangeNr",
            linehl = "GitSignsChangeLn",
          },
          delete = { hl = "GitSignsDelete", text = "_", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
          topdelete = {
            hl = "GitSignsDelete",
            text = "‾",
            numhl = "GitSignsDeleteNr",
            linehl = "GitSignsDeleteLn",
          },
          changedelete = {
            hl = "GitSignsChange",
            text = "~",
            numhl = "GitSignsChangeNr",
            linehl = "GitSignsChangeLn",
          },
          untracked = { hl = "GitSignsAdd", text = "┆", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
        },
      })
    end,
  },

  {
    'mrloop/telescope-git-branch.nvim',
    config = function ()
      vim.keymap.set('n', '<leader>df', require('git_branch').files , { desc = 'Telescope: Show git diff.' })
    end
  }
}
