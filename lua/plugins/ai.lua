if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

local run_shell_cmd = function(shcmd)
  local handle = io.popen(shcmd)
  if handle == nil then return end

  local result = handle:read("*a")
  handle:close()

  return result
end

local default_adapter = "ollama"
if OPENWEBUI_ENABLED then
  default_adapter = "gemma3"
end

local vectorcode_exists = pcall(run_shell_cmd, "which vectorcode")

-- starting configuration here, above are just general flags

return {
  {
    "Davidyz/VectorCode",
    lazy = false,
    build = "uvenv upgrade vectorcode",
    version = "*",
    dependencies = { "nvim-lua/plenary.nvim" },

    config = function ()
      if not vectorcode_exists then return end

      local ok, cw_gitdir = pcall(run_shell_cmd, "git rev-parse --git-dir 2&> /dev/null")
      if not ok or cw_gitdir == nil then
        vim.notify(
          "not in git repo, not initializing vectorcode; err: " .. cw_gitdir,
          vim.log.levels.WARN
        )
        return
      end

      local vc_cmd = "vectorcode --project_root=" .. cw_gitdir:gsub("%s+", "") .. " init 2>&1 | tee"
      local vectocode_started, vectorcode_init_out = pcall(run_shell_cmd, vc_cmd)
      if vectocode_started then
        vim.notify(vectorcode_init_out, vim.log.levels.INFO)
      else
        vim.notify(vectorcode_init_out, vim.log.levels.WARN)
      end
    end
  },

  {
    'olimorris/codecompanion.nvim',
    lazy = true,
    cmd = "CodeCompanionActions",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
      "Davidyz/VectorCode",
    },

    keys = {
      { '<leader>c', ':CodeCompanionActions<CR>', { desc = 'CodeCompanion: Actions.' } },
    },

    config = function (_, opts)
      opts = opts or {}

      opts.adapters = opts.adapters or {}
      opts.adapters["gemma3"] = function()
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
            -- NOTE: startup time might be better with 1B
            -- 1080ti over proxmox pci passthrough to talos os is takes a few seconds for 4B
            -- and 12B takes FOREVER, t/s is also not too good
            model = { default = "gemma3:4B" },
          },
        })
      end
      opts.adapters["ollama"] = function()
        return require("codecompanion.adapters").extend("ollama", {
          model = "qwen2.5-coder:7b",
          opts = {
            allow_insecure = true,
            show_defaults = true,
          },
          env = {
            url = OLLAMA_URL,
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

      local cc_strats = {
        chat = {
          adapter = default_adapter,
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
      if vectorcode_exists then
        local vc_int = require("vectorcode.integrations")
        cc_strats.chat.slash_commands = { codebase = vc_int.codecompanion.chat.make_slash_command() }
        cc_strats.chat.tools = {
          vectorcode = {
            description = "Run VectorCode to retrieve the project context.",
            callback = vc_int.codecompanion.chat.make_tool(),
          }
        }
      end
      opts.strategies = cc_strats

      require('codecompanion').setup(opts)

      if OPENWEBUI_ENABLED then
        vim.notify('codecompanion adapter ' .. default_adapter .. 'AI via ' .. OPENWEBUI_URL .. ' enabled', vim.log.levels.INFO)
        return
      end

      if OLLAMA_ENABLED then
        vim.notify('codecompanion adapter ' .. default_adapter .. 'AI via ' .. OLLAMA_URL .. ' enabled', vim.log.levels.INFO)
      end
    end
  }
}
