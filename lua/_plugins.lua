-- Auto install plugin
local fn = vim.fn
local install_path = fn.stdpath('data') ..
  '/site/pack/packer/start/packer.nvim'
if fn.empty(fn.glob(install_path)) > 0 then
  packer_bootstrapped = fn.system(
    {
      'git', 'clone',
      '--depth', '1',
      'https://github.com/wbthomason/packer.nvim',
      install_path
    }
  )
end

return require('packer').startup(function(use)
  config = {
      display = {
        open_fn = require('packer.util').float,
      }
  }

  -- base requirements
  use { 'wbthomason/packer.nvim' }
  use { 'nvim-tree/nvim-web-devicons', after = 'packer.nvim' }
  -- this particular one for some reason can't just be required for some
  use 'nvim-lua/plenary.nvim'

  -- editing super-chargers
  use {
    'folke/zen-mode.nvim',
    config = function() require('plugins/zen-mode') end
  }
  use {
    'nvim-treesitter/nvim-treesitter',
    requires = {
      { 'windwp/nvim-ts-autotag' }
    },
    run = ':TSUpdate',
    config = function() require 'plugins/treesitter' end
  }
  use 'nvim-treesitter/playground'
  use 'pseewald/vim-anyfold'
  use 'Yggdroot/indentLine'
  use {
    'folke/twilight.nvim',
    config = function() require('twilight').setup() end
  }
  use {
    'rmagatti/auto-session',
    config = function() require('plugins/auto-session') end
  }
  use {
    'numToStr/Comment.nvim',
    requires = { { 'JoosepAlviste/nvim-ts-context-commentstring' } },
    config = function() require('plugins/comments') end
  }
  use {
    'kylechui/nvim-surround',
    tag = "*",
    config = function() require("nvim-surround").setup({}) end
  }

  -- finders, navigation
  -- TODO: not sure what other things I need to apt-get for this here
  use { 'nvim-telescope/telescope-fzf-native.nvim', run = 'make' }
  use {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    requires = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons", -- not strictly required, but recommended
      "MunifTanjim/nui.nvim",
      "3rd/image.nvim", -- Optional image support in preview window: See `# Preview Mode` for more information
    },
    config = function() require('plugins/neotree') end
  }
  use {
    'nvim-telescope/telescope.nvim',
    requires = {
      {'nvim-lua/plenary.nvim'},
      {'nvim-telescope/telescope-fzf-native.nvim'},
    },
    config = function() require('plugins/telescope') end
  }
  use {'stevearc/dressing.nvim'}
  use {
    'ggandor/leap.nvim',
    config = function() require 'plugins/leap' end
  }
  use {
    "alexghergh/nvim-tmux-navigation",
    config = function() require 'plugins/tmux' end
  }
  use {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    requires = { 'nvim-lua/plenary.nvim' },
    config = function() require 'plugins/harpoon' end
  }

  -- copy-pasta from https://github.com/ThePrimeagen/init.lua/blob/master/lua/theprimeagen/packer.lua
  use {
    'VonHeikemen/lsp-zero.nvim',
    branch = 'v3.x',
    requires = {
      -- LSP Support
      {'neovim/nvim-lspconfig'},
      {'williamboman/mason.nvim'},
      {'williamboman/mason-lspconfig.nvim'},

      -- Autocompletion
      {'hrsh7th/nvim-cmp'},
      {'hrsh7th/cmp-buffer'},
      {'hrsh7th/cmp-path'},
      {'saadparwaiz1/cmp_luasnip'},
      {'hrsh7th/cmp-nvim-lsp'},
      {'hrsh7th/cmp-nvim-lua'},
      {'andersevenrud/cmp-tmux'},

      -- Snippets
      {'L3MON4D3/LuaSnip'},
      {'rafamadriz/friendly-snippets'},

      -- other trash
      -- { 'github/copilot.vim', branch = 'release' },
    },
    config = function() require 'plugins/lsp' end
  }

  -- git things
  use {
    'lewis6991/gitsigns.nvim',
    requires = { 'nvim-lua/plenary.nvim' }
  }
  use 'tpope/vim-fugitive'

  -- misc awesome things
  use {
    'hoob3rt/lualine.nvim',
    after = 'nvim-web-devicons',
    config = function() require 'plugins/lualine' end
  }
  use 'shaunsingh/nord.nvim'
  use 'eandrju/cellular-automaton.nvim'
  use {
      "karb94/neoscroll.nvim",
      config = function() require 'plugins/neoscroll' end
  }
  use {
    'folke/which-key.nvim',
    config = function()
      vim.o.timeout = true
      vim.o.timeoutlen = 500
      require("which-key").setup {}
    end
  }

  if packer_bootstrapped then
    require('packer').sync()
    -- I have no idea if this actually works
    vim.api.nvim_command [[UpdateRemotePlugins]]
  end
end)
