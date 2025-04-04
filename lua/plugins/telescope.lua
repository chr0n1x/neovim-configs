return {
  'nvim-telescope/telescope.nvim',
  -- lazily load so that we eager load treesitter
  lazy = true,
  dependencies = {
    'nvim-lua/plenary.nvim',
    'stevearc/dressing.nvim',
    { 'nvim-telescope/telescope-fzf-native.nvim', run = 'make' }
  },
  init = function()
    local telescope = require("telescope")
    local actions = require("telescope.actions")

    telescope.setup({
      defaults = {
        path_display = { "smart" },
        mappings = {
          i = {
            ["<C-k>"] = actions.move_selection_previous, -- move to prev result
            ["<C-j>"] = actions.move_selection_next, -- move to next result
            ["<C-q>"] = actions.send_selected_to_qflist + actions.open_qflist,
          },
        },
      },
    })

    local builtin = require('telescope.builtin')
    -- TODO: no idea how to make this work yet
    -- local default_opts = { hidden = true, file_ignore_patterns = {".git/"} }
    vim.keymap.set('n', '<leader>f', builtin.treesitter, { desc = 'Telescope: token.' })
    vim.keymap.set('n', '<leader>g', builtin.live_grep, { desc = 'Telescope: [rip]grep cwd.' })
    vim.keymap.set('n', '<leader>p', builtin.find_files, { desc ='Telescope: search cwd for file.' })
    vim.keymap.set('n', '<leader>r', builtin.lsp_references, { desc = 'Telescope: show references for token under cursor.' })
    vim.keymap.set('n', '<leader>m', builtin.marks, { desc = 'Telescope: show marks.' })

    telescope.load_extension("fzf")
  end
}
