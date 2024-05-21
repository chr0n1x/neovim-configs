local nmap = vim.api.nvim_set_keymap

vim.g.mapleader = ' '

-- Note that some of these require plugins
-- these are put here because most of these I consider core functionality
-- that's ingrained in my muscle memory. There may be more key mappings in the
-- plugins/ dir tied to specific plugins. in nvim itself, hit <Space> and do
-- nothing to let the which-key plugin list possible keymappings

-- buffer navigation
nmap('n', '<leader>s',       ':/<C-r><C-w>/<CR>',                                                 {noremap = true, desc = 'Search word underneath cursor' })
nmap('n', '<leader>j',       ':lua require("neoscroll").scroll("0.25", "true", "250", nil)<CR>',  {noremap = true, desc = 'NeoScroll (smooth) down' })
nmap('n', '<leader>k',       ':lua require("neoscroll").scroll("-0.25", "true", "250", nil)<CR>', {noremap = true, desc = 'NeoScroll (smooth) up'})

-- directory/tree navigation
nmap('n', '<leader><tab>',   ':CHADopen<CR>',                                                     {noremap = true})
nmap('n', '<leader>f',      ':lua require"telescope.builtin".treesitter{}<CR>',                   {noremap = true, desc = 'Telescope Find with Treesitter' })
nmap('n', '<leader>p',      ':lua require"telescope.builtin".find_files({ hidden = true })<CR>',  {noremap = true, desc = 'Telescope File Fuzzy Find' })
nmap('n', '<leader>g',      ':Telescope live_grep<CR>',                                           {noremap = true, desc = 'Telescope LiveGrep in CWD' })

-- tab navigation
nmap('n', '<leader>n',       ':tabnext<CR>',                                    {noremap = true})
nmap('n', '<leader>b',       ':tabprevious<CR>',                                {noremap = true})
nmap('n', '<leader>o',       ':tabe<space>',                                    {noremap = true})

-- editor visuals & "ergonomics"
nmap('n', '<leader>z',       ':ZenMode | Twilight!!<CR>',                       {noremap = true})
nmap('n', '<leader>m',       ':set mouse=a<CR>',                                {noremap = true})
nmap('n', '<leader>M',       ':set mouse=c<CR>',                                {noremap = true})

-- misc 
nmap('n', '<leader>w',       ':w<CR>',                                          {noremap = true})
nmap('n', '<leader><space>', ':noh <bar> e<CR>',                                {noremap = true})
nmap('n', '<leader>q',       ':q<CR>',                                          {noremap = true})

-- utility scripts
-- pretty-format JSON in the current buffer/file
nmap('n', '<leader>J',       ':%!python3 -m json.tool --sort-keys<CR>',         {noremap = true, desc = 'Use python to pretty-format JSON' })

-- DEADGE
nmap('n', '<leader>F',       ':CellularAutomaton make_it_rain<CR>',             {noremap = true, desc = 'Am sadge' })
