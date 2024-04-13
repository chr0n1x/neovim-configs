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
  },
  -- base requirements
  use 'wbthomason/packer.nvim'
  use { 'kyazdani42/nvim-web-devicons', after = 'packer.nvim' }

  -- editing super-chargers
  use {
    'folke/zen-mode.nvim',
    config = function() require('plugins/zen-mode') end
  }
  use {
      'ms-jpq/coq_nvim',
      after = 'packer.nvim',
      branch = 'coq',
      config = function() require 'plugins/coq' end
  }
  use {
    'ms-jpq/coq.artifacts',
    after = 'coq_nvim',
    branch = 'artifacts'
  }
  use {
    'nvim-treesitter/nvim-treesitter',
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

  -- finders, navigation
  use { 'ms-jpq/chadtree' }
  use {
    'nvim-telescope/telescope.nvim',
    requires = { {'nvim-lua/plenary.nvim'} }
  }
  use {'stevearc/dressing.nvim'}
  use {
    'ggandor/leap.nvim',
    config = function() require 'plugins/leap' end
  }

  -- copy-pasta from https://github.com/ThePrimeagen/init.lua/blob/master/lua/theprimeagen/packer.lua
  use {
    'VonHeikemen/lsp-zero.nvim',
    branch = 'v1.x',
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

        -- Snippets
        {'L3MON4D3/LuaSnip'},
        {'rafamadriz/friendly-snippets'},
    }
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

  if packer_bootstrapped then
    require('packer').sync()
    -- I have no idea if this actually works
    vim.api.nvim_command [[UpdateRemotePlugins]]

    require('nvim-treesitter.configs').setup { endwise = { enable = true } }
  end
end)
