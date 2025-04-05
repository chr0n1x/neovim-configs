return {
  'olimorris/codecompanion.nvim',
  opts = {
    strategies = {
      chat = {
        adapter = "gemma3"
      }
    },

    adapters = {
      opts = {
        allow_insecure = true,
        show_defaults = false,
        log_level = "TRACE",
      },

      gemma3_4B = function()
        return require("codecompanion.adapters").extend("openai_compatible", {
          opts = {
            allow_insecure = true,
            show_defaults = false,
          },

          env = {
            url = os.getenv("OPEN_WEBUI_URL"),
            api_key = os.getenv("OPEN_WEBUI_JWT"),
            chat_url = "/api/chat/completions",
            models_endpoint = "/api/models",
          },
          schema = {
            -- NOTE: startup time might be better with 1B
            -- 1080ti over proxmox pci passthrough to talos os is takes a few seconds
            model = { default = "gemma3:4B" },
          },
        })
      end,
    }
  }
}
