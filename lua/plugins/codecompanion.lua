if IN_PERF_MODE then return {} end

if OLLAMA_NVIM_DISABLED then return {} end

OLLAMA_ADAPTER_NAME = "ollama"

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
    adapter = OLLAMA_ADAPTER_NAME,
    model = OLLAMA_MODEL,
  },
  chat = {
    adapter = OLLAMA_ADAPTER_NAME,
    model = OLLAMA_MODEL,
    roles = {
      user = "🤓 " .. os.getenv("USER") .. ' (type something, send w/ ctrl+s)',
    },
  },
  inline = {
    adapter = DEFAULT_AI_ADAPTER,
    adapter = OLLAMA_ADAPTER_NAME,
    model = OLLAMA_MODEL,
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
    { '<leader>c', ':CodeCompanionActions<CR>', desc = 'CodeCompanion: Actions.' },
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
        model = { default = OLLAMA_MODEL },
        temperature = { default = 0.6 },
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

    cc_strats.inline.adapter = OLLAMA_ADAPTER_NAME

    opts.adapters.http[OLLAMA_ADAPTER_NAME] = function()
      return require("codecompanion.adapters").extend("ollama", ollama_cfg)
    end

    opts.strategies = cc_strats
    require('codecompanion').setup(opts)

    local statusmsg = 'CodeCompanion AI adapter(s) configured:\n\n'
    statusmsg = statusmsg .. '✅💻🦙' .. OLLAMA_MODEL .. ' via ' ..
    OLLAMA_URL .. ' (' .. OLLAMA_ADAPTER_NAME .. ')'
    vim.notify(statusmsg, vim.log.levels.INFO, setup_notification_cfg)
  end
}
