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

local nmap = vim.api.nvim_set_keymap
nmap('n', '<leader>f', ':lua require"telescope.builtin".treesitter({ hidden = true, file_ignore_patterns = {".git/"} })<CR>',     {noremap = true, desc = 'Telescope: token.' })
nmap('n', '<leader>g', ':lua require"telescope.builtin".live_grep({ hidden = true, file_ignore_patterns = {".git/"} })<CR>',      {noremap = true, desc = 'Telescope: [rip]grep cwd.' })
nmap('n', '<leader>p', ':lua require"telescope.builtin".find_files({ hidden = true, file_ignore_patterns = {".git/"} })<CR>',     {noremap = true, desc = 'Telescope: search cwd for file.' })
nmap('n', '<leader>r', ':lua require"telescope.builtin".lsp_references({ hidden = true, file_ignore_patterns = {".git/"} })<CR>', {noremap = true, desc = 'Telescope: show references for token under cursor.' })
nmap('n', '<leader>m', ':lua require"telescope.builtin".marks()<CR>',                                                             {noremap = true, desc = 'Telescope: show marks.' })

telescope.load_extension("fzf")
