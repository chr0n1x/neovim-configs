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
nmap('n', '<leader>f',      ':lua require"telescope.builtin".treesitter({ hidden = true, file_ignore_patterns = {".git/"} })<CR>',  {noremap = true, desc = 'Telescope Find with Treesitter' })
nmap('n', '<leader>p',      ':lua require"telescope.builtin".find_files({ hidden = true, file_ignore_patterns = {".git/"} })<CR>',  {noremap = true, desc = 'Telescope File Fuzzy Find' })
nmap('n', '<leader>g',      ':lua require"telescope.builtin".live_grep({ hidden = true, file_ignore_patterns = {".git/"} })<CR>',   {noremap = true, desc = 'Telescope LiveGrep in CWD' })

telescope.load_extension("fzf")
