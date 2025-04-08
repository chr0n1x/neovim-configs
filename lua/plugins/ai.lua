local openwebui_url = os.getenv("OPEN_WEBUI_URL")
local openwebui_jwt = os.getenv("OPEN_WEBUI_JWT")
local no_openwebui_cfg = function ()
  return openwebui_jwt == "" or openwebui_jwt == nil or
    openwebui_url == "" or openwebui_url == nil
end

local ollama_url = os.getenv("OLLAMA_HOST")
local no_ollama_cfg = function ()
  return ollama_url == "" or ollama_url == nil
end

if no_openwebui_cfg() and no_ollama_cfg() then
  return {}
end

local default_adapter = "ollama"
if not no_openwebui_cfg() then
  default_adapter = "gemma3"
end

return {
  {
    'olimorris/codecompanion.nvim',

    config = true,

    dependencies = {
      -- explicitly listing here, want to notify when we're connecting to anything
      "folke/snacks.nvim",
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
      "Davidyz/VectorCode",
      "ibhagwan/fzf-lua",
    },
    -- fx here is to ensure that we can require vectorcode.integrations below
    opts = function(_, opts)
      opts = opts or {}
      opts.adapters = opts.adapters or {}

      opts.strategies = {
        chat = {
          adapter = default_adapter,
          slash_commands = {
            codebase = require("vectorcode.integrations").codecompanion.chat.make_slash_command(),
          },
          tools = {
            vectorcode = {
              description = "Run VectorCode to retrieve the project context.",
              callback = require("vectorcode.integrations").codecompanion.chat.make_tool(),
            }
          },
        },
        inline = {
          adapter = default_adapter,
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

      opts.adapters["gemma3"] = function()
        return require("codecompanion.adapters").extend("openai_compatible", {
          opts = {
            show_defaults = true,
            display = { show_settings = true }
          },

          env = {
            url = openwebui_url,
            api_key = openwebui_jwt,
            chat_url = "/api/chat/completions",
            models_endpoint = "/api/models",
          },
          schema = {
            -- NOTE: startup time might be better with 1B
            -- 1080ti over proxmox pci passthrough to talos os is takes a few seconds for 4B
            -- and 12B takes FOREVER, t/s is also not too good
            model = { default = "gemma3:4B" },
          },
        })
      end

      opts.adapters["ollama"] = function()
        return require("codecompanion.adapters").extend("ollama", {
          opts = {
            allow_insecure = true,
            show_defaults = true,
          },
          env = {
            url = ollama_url,
            api_key = "OLLAMA_API_KEY",
          },
          headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer ${api_key}",
          },
          parameters = {
            sync = true,
          },
        })
      end

      return opts
    end,

    init = function()
      -- TODO: too tired/lazy to figure out a way to do this "correctly"
      vim.keymap.set('n', '<leader>c', ':CodeCompanionActions<CR>', { desc = 'CodeCompanion: Actions.' })

      local notifier = require('snacks.notifier')
      if not no_openwebui_cfg() then
        notifier.notify('codecompanion adapter ' .. default_adapter .. 'AI via ' .. openwebui_url .. ' enabled', vim.log.levels.INFO)
        return
      end

      if not no_ollama_cfg() then
        notifier.notify('codecompanion adapter ' .. default_adapter .. 'AI via ' .. ollama_url .. ' enabled', vim.log.levels.INFO)
      end
    end
  }
}
