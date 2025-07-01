if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

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
if VECTORCODE_INSTALLED then
  table.insert(deps, "Davidyz/VectorCode")
end

local cc_strats = {
  chat = {
    adapter = DEFAULT_AI_ADAPTER,
    roles = {
      user = "🤓 " .. os.getenv("USER") .. ' (type something, send w/ ctrl+s)',
    },
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
      opts.adapters[OPENWEBUI_ADAPTER_NAME] = function()
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
          }
        })
      end

      cc_strats.chat.adapter = OPENWEBUI_ADAPTER_NAME
      cc_strats.chat.roles.llm = "🤖 " .. OPENWEBUI_MODEL
    end

    local ollama_chat_cfg_name = OLLAMA_ADAPTER_NAME .. "-chat"
    if OLLAMA_ENABLED then
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
          -- does not work as of now
          -- think = { default = false },
        }
      }

      if OLLAMA_API_KEY ~= '' then
        ollama_cfg.env.api_key = OLLAMA_API_KEY
        ollama_cfg.headers["Authorization"] = "Bearer ${api_key}"
      end

      if OPENWEBUI_DISABLED then
        local ollama_chat_cfg = vim.deepcopy(ollama_cfg)
        -- assume that we're trying to run the same GGUF model here
        ollama_chat_cfg.schema.model.default = OPENWEBUI_MODEL

        opts.adapters[ollama_chat_cfg_name] = function()
          return require("codecompanion.adapters").extend("ollama", ollama_chat_cfg)
        end

        cc_strats.chat.adapter = ollama_chat_cfg_name
        cc_strats.chat.roles.llm = "🦙 " .. OPENWEBUI_MODEL
      end

      cc_strats.inline.adapter = OLLAMA_ADAPTER_NAME

      opts.adapters[OLLAMA_ADAPTER_NAME] = function()
        return require("codecompanion.adapters").extend("ollama", ollama_cfg)
      end
    end

    opts.strategies = cc_strats
    require('codecompanion').setup(opts)

    local statusmsg = 'CodeCompanion AI adapter(s) configured:\n\n'
    if OPENWEBUI_ENABLED then
      statusmsg = statusmsg .. '✅ 🤖 ' .. OPENWEBUI_MODEL .. ' via ' ..
      OPENWEBUI_URL .. ' (' .. OPENWEBUI_ADAPTER_NAME .. ') \n'
    end
    if OLLAMA_ENABLED then
      if OPENWEBUI_DISABLED then
        statusmsg = statusmsg .. "✅ 🦙 "  .. OPENWEBUI_MODEL .. ' via ' ..
        OLLAMA_URL .. ' (' .. OLLAMA_ADAPTER_NAME .. ')\n'
      end

      statusmsg = statusmsg .. '✅💻🦙' .. OLLAMA_MODEL .. ' via ' ..
      OLLAMA_URL .. ' (' .. OLLAMA_ADAPTER_NAME .. ' inline)'
    end

    if OLLAMA_ENABLED or OPENWEBUI_ENABLED then
      vim.notify(statusmsg, vim.log.levels.INFO, setup_notification_cfg)
    end
  end
}
