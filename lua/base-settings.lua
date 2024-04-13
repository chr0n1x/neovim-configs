local opts = vim.opt

-- base vim config - bools
opts.autoread       = true
opts.autoindent     = false
opts.cursorline     = true
opts.expandtab      = true
opts.gdefault       = true
opts.hidden         = true
opts.hlsearch       = true
opts.ignorecase     = true
opts.incsearch      = true
opts.lazyredraw     = true
opts.compatible     = false
opts.number         = true
opts.ruler          = true
opts.relativenumber = true
opts.showmatch      = true
opts.showmode       = true
opts.showcmd        = true
opts.smartindent    = true
opts.termguicolors  = true
opts.ttyfast        = true
opts.wildmenu       = true

-- base vim config - non-bools
vim.api.nvim_command([[filetype plugin indent on]])

opts.backspace      = 'indent,eol,start'
opts.completeopt    = "menu,menuone,noselect"
opts.encoding       = 'utf-8'
opts.formatoptions  = 'qrn1'
opts.foldexpr       = "v:lua.vim.treesitter.foldexpr()"
opts.foldlevelstart = 99
opts.foldmethod     = 'syntax'
opts.foldtext       = "v:lua.vim.treesitter.foldtext()"
opts.guifont        = 'Consolas 20'
opts.laststatus     = 2
opts.regexpengine   = 1
opts.shiftwidth     = 2
opts.softtabstop    = 2
opts.scrolloff      = 3
opts.syntax         = 'on'
opts.re             = 0
opts.tabstop        = 4
opts.wildignore     = '*/tmp/*,*.so,*.swp,*.zip,*/node_modules/*'
opts.wildmode       = 'list:longest'
