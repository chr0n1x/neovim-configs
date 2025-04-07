local openwebui_url = os.getenv("OPEN_WEBUI_URL")
local openwebui_jwt = os.getenv("OPEN_WEBUI_JWT")
local either_empty = function ()
  return openwebui_jwt == "" or openwebui_jwt == nil or
    openwebui_url == "" or openwebui_url == nil
end
if either_empty() then
  return {}
end

return {
  'olimorris/codecompanion.nvim',

  -- explicitly listing here, want to notify when we're connecting to anything
  dependencies = { "folke/snacks.nvim" },
  opts = {
    display = {
      chat = {
        show_settings = true
      }
    },
    strategies = {
      chat = { adapter = "gemma3" },
      inline = {
        adapter = "gemma3",
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
    },

    adapters = {
      opts = {
        allow_insecure = true,
        show_defaults = false,
        log_level = "TRACE",
      },

      gemma3 = function()
        return require("codecompanion.adapters").extend("openai_compatible", {
          opts = {
            allow_insecure = true,
            show_defaults = false,
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
      end,
    }
  },
  init = function()
    local notifier = require('snacks.notifier')
    notifier.notify('! Using codecompanion AI via ' .. openwebui_url, vim.log.levels.INFO)

    -- TODO: too tired/lazy to figure out a way to do this "correctly"
    vim.keymap.set('n', '<leader>c', ':CodeCompanionActions<CR>', { desc = 'CodeCompanion: Actions.' })
  end
}
