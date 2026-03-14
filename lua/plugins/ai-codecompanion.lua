if IN_PERF_MODE or (not OLLAMA_ENABLED) then return {} end

local OLLAMA_ADAPTER_NAME = "ollama"
local adapter = os.getenv("CODECOMPANION_ADAPTER") or OLLAMA_ADAPTER_NAME
-- NOTE: can be a heavier model; we don't need to deal w/things like debounce
local model = os.getenv("CODECOMPANION_MODEL") or OLLAMA_MODEL
local model_name_pieces = vim.split(model, "/")
local model_name_short = model_name_pieces[#model_name_pieces]

-- notification things
local setup_notification_cfg = {
  title = "🤖 CodeCompanion",
  style = "minimal",
  timeout = 1000,
}

local deps = {
  "nvim-lua/plenary.nvim",
  "nvim-treesitter/nvim-treesitter",
}

local cc_strats = {
  cmd = {
    adapter = adapter,
    model = model,
  },
  chat = {
    adapter = adapter,
    model = model,
    send = {
      keymaps = {
        -- a bit better than ctrl+s, i.e. shift-enter
        -- but we're already typing in insert mode so iunno
        -- based on this https://github.com/olimorris/codecompanion.nvim/blob/main/doc/configuration/chat-buffer.md#keymaps
        modes = { n = "<leader><CR>", i = "<C-s>" },
      },
    },
    roles = {
      user = "🤓👇 " .. os.getenv("USER") .. ' (type something, send w/ ctrl+s)',
    },
  },
  inline = {
    adapter = adapter,
    model = model,
    keymaps = {
      accept_change = {
        modes = { n = "ga" },
        description = "Accept the suggested change",
      },
      reject_change = {
        modes = { n = "gr" },
        description = "Reject the suggested change",
      }
    }
  }
}

return {
  'olimorris/codecompanion.nvim',
  lazy = false,
  cmd = "CodeCompanionActions",
  dependencies = deps,

  keys = {
    -- the weird :'<,'> stuff is due to this
    -- https://github.com/olimorris/codecompanion.nvim/issues/2650
    {
      '<leader>c',
      ":'<,'>CodeCompanionChat Add /buffer<CR>",
      mode = "v",
      desc = 'CodeCompanion: add buffer selection into chat.'
    },
    {
      '<leader>c',
      "V:'<,'>CodeCompanionChat Add /buffer<CR>",
      mode = "n",
      desc = 'CodeCompanion: dump current line into chat.'
    }
  },

  config = function (_, opts)
    opts = opts or {}

    opts.adapters = opts.adapters or {}
    opts.adapters.http = opts.adapters.http or {}

    local ollama_cfg = {
      opts = {
        allow_insecure = true,
        show_defaults = true,
      },
      env = {
        url = OLLAMA_URL,
      },
      headers = {
        ["Content-Type"] = "application/json",
      },
      parameters = {
        sync = true,
      },
      schema = {
        model = { default = model },
        temperature = { default = 0.95 },
        top_p = { default = 0.95 },
        min_p = { default = 0.00 },
        top_k = { default = 40 },
        think = { default = false },
      }
    }

    if OLLAMA_API_KEY ~= '' then
      ollama_cfg.env.api_key = OLLAMA_API_KEY
      ollama_cfg.headers["Authorization"] = "Bearer ${api_key}"
    end

    opts.adapters.http[OLLAMA_ADAPTER_NAME] = function()
      return require("codecompanion.adapters").extend("ollama", ollama_cfg)
    end

    opts.strategies = cc_strats

    opts.display = opts.display or {
      chat = {
        window = {
          title = "🦙 " .. model_name_short,
          buflisted = false,
          sticky = false, -- window follows when switching tabs

          layout = "float", -- float|vertical|horizontal|tab|buffer
          floating_window = {
            row =  function() -- vim.o.lines,
              return vim.o.lines - 128
            end,
            col=  function() -- vim.o.lines,
              return vim.o.columns + 512
            end,
            opts = {
              wrap = false,
              number = false,
              relativenumber = false,
            },
          },

          width = 0.3,
          height = 0.8,

          full_height = false,
          position = "right", -- left|right|top|bottom (nil will default depending on vim.opt.splitright|vim.opt.splitbelow)
          border = "single",
          relative = "cursor",

          -- Ensure that long paragraphs of markdown are wrapped
          opts = {
            breakindent = true,
            linebreak = true,
            wrap = true,
          },
        },
      },
    }

    require('codecompanion').setup(opts)

    local statusmsg = 'CodeCompanion AI adapter(s) configured:\n\n'
    statusmsg = statusmsg .. '✅💻🦙 ' .. model_name_short .. ' via ' .. adapter
    vim.notify(statusmsg, vim.log.levels.INFO, setup_notification_cfg)
  end
}
