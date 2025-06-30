if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

-- notification things
local setup_notification_cfg = {
  title = "AI Plugin Setup",
  style = "minimal",
  timeout = 1000,
}

local deps = {
  "nvim-lua/plenary.nvim",
  "nvim-treesitter/nvim-treesitter",
}
if VECTORCODE_INSTALLED then
  table.insert(deps, "Davidyz/VectorCode")
end

local cc_strats = {
  chat = {
    adapter = DEFAULT_AI_ADAPTER,
  },
  inline = {
    adapter = DEFAULT_AI_ADAPTER,
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

if OLLAMA_ENABLED then
  cc_strats.inline.adapter = OLLAMA_ADAPTER_NAME
end
if OPENWEBUI_ENABLED then
  cc_strats.chat.adapter = OPENWEBUI_ADAPTER_NAME
end

return {
  'olimorris/codecompanion.nvim',
  lazy = true,
  cmd = "CodeCompanionActions",
  dependencies = deps,

  keys = {
    { '<leader>c', ':CodeCompanionActions<CR>', desc = 'CodeCompanion: Actions.' },
  },

  config = function (_, opts)
    opts = opts or {}

    opts.adapters = opts.adapters or {}

    if OPENWEBUI_ENABLED then
      opts.adapters["openwebui"] = function()
        return require("codecompanion.adapters").extend("openai_compatible", {
          opts = {
            show_defaults = true,
            display = { show_settings = true }
          },

          env = {
            url = OPENWEBUI_URL,
            api_key = OPENWEBUI_JWT,
            chat_url = "/api/chat/completions",
            models_endpoint = "/api/models",
          },
          schema = {
            model = { default = OPENWEBUI_MODEL },
          },
        })
      end
    end

    if OLLAMA_ENABLED then
      opts.adapters["ollama"] = function()
        return require("codecompanion.adapters").extend("ollama", {
          model = OLLAMA_MODEL,
          opts = {
            allow_insecure = true,
            show_defaults = true,
          },
          env = {
            url = OLLAMA_URL,
            api_key = OLLAMA_API_KEY,
          },
          headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer ${api_key}",
          },
          parameters = { sync = true },
        })
      end
    end

    opts.strategies = cc_strats
    require('codecompanion').setup(opts)

    local statusmsg = 'codecompanion AI adapter(s) configured:\n\n'
    if OPENWEBUI_ENABLED then
      statusmsg = statusmsg .. '> ' .. OPENWEBUI_MODEL .. ' via ' ..
      OPENWEBUI_URL .. ' (' .. OPENWEBUI_ADAPTER_NAME .. ') \n'
    end
    if OLLAMA_ENABLED then
      statusmsg = statusmsg .. '> ' .. OLLAMA_MODEL .. ' via ' ..
      OLLAMA_URL .. ' (' .. OLLAMA_ADAPTER_NAME .. ')'
    end

    if OLLAMA_ENABLED or OPENWEBUI_ENABLED then
      vim.notify(statusmsg, vim.log.levels.INFO, setup_notification_cfg)
    end
  end
}
