if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

require('../util/shell')

-- notification things
local setup_notification_cfg = {
  title = "AI Plugin Setup",
  -- render = "compact"
}

local deps = {
  "nvim-lua/plenary.nvim",
  "nvim-treesitter/nvim-treesitter",
}
local vectorcode_exists = pcall(RUN_SHELL_CMD, 'which vectorcode')
if vectorcode_exists then
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

-- starting configuration here, above are just general flags

local ai_plugins = {
  {
    'olimorris/codecompanion.nvim',
    lazy = true,
    cmd = "CodeCompanionActions",
    dependencies = deps,

    keys = {
      { '<leader>c', ':CodeCompanionActions<CR>', { desc = 'CodeCompanion: Actions.' } },
    },

    config = function (_, opts)
      opts = opts or {}

      opts.adapters = opts.adapters or {}
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
            -- NOTE: startup time might be better with 1B
            -- 1080ti over proxmox pci passthrough to talos os is takes a few seconds for 4B
            -- and 12B takes FOREVER, t/s is also not too good
            model = { default = "gemma3:27B" },
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
        vim.notify(
          'codecompanion adapter ' ..
            DEFAULT_AI_ADAPTER .. ' AI via ' ..
            OPENWEBUI_URL .. ' enabled',
          vim.log.levels.INFO,
          setup_notification_cfg
        )
      end

      if OLLAMA_ENABLED then
        vim.notify(
          'codecompanion adapter ' ..
            DEFAULT_AI_ADAPTER ..
            ' AI via ' .. OLLAMA_URL ..
            ' enabled',
          vim.log.levels.INFO,
          setup_notification_cfg
        )
      end
    end
  },
}

if vectorcode_exists then
  local vc_notification_cfg = { title = "VectorCode", render = "compact" }
  local vectorise_codebase = function ()
    local ext = vim.fn.expand('%:e')
    local partial_glob = vim.fn.expand('%:h') .. "/**/*." .. ext
    if #ext == 0 then
      vim.notify(
        "Not Vectorising, no files found in " .. partial_glob,
        vim.log.levels.ERROR,
        vc_notification_cfg
      )
      return
    end

    local file_glob = vim.fn.expand('%:p:h') .. "/**/*." .. ext
    vim.fn.jobstart(
      'vectorcode vectorise ' .. file_glob,
      {
        on_exit = function()
          vim.notify("vectorised code in " .. partial_glob, vim.log.levels.INFO, vc_notification_cfg)
        end
      }
    )
  end

  table.insert(
    ai_plugins,
    {
      "Davidyz/VectorCode",
      lazy = false,
      build = "uvenv upgrade vectorcode",
      -- version = "*",
      dependencies = { "nvim-lua/plenary.nvim" },

      keys = {
        { '<leader>v', ':VectorCode register<CR>', { desc = 'VectorCode' } },
        { '<leader>vv', vectorise_codebase, { desc = 'vectorise current codebase.' } },
      },

      config = function ()
        if not vectorcode_exists then return end

        local ok, cw_gitdir = pcall(RUN_SHELL_CMD, "git rev-parse --git-dir 2&> /dev/null")
        if not ok or cw_gitdir == nil then
          vim.notify(
            "not in git repo, not initializing vectorcode; err: " .. cw_gitdir,
            vim.log.levels.WARN,
            setup_notification_cfg
          )
          return
        end

        local vc_cmd = "vectorcode --project_root=" .. cw_gitdir:gsub("%s+", "") .. " init 2>&1 | tee"
        local vectocode_started, vectorcode_init_out = pcall(RUN_SHELL_CMD, vc_cmd)
        if vectocode_started then
          vim.notify(vectorcode_init_out, vim.log.levels.INFO, setup_notification_cfg)
        else
          vim.notify(vectorcode_init_out, vim.log.levels.WARN, setup_notification_cfg)
        end

        vim.api.nvim_create_autocmd(
          'LspAttach',
          {
            callback = function()
              local cacher = require("vectorcode.config").get_cacher_backend()
              local bufnr = vim.api.nvim_get_current_buf()
              cacher.async_check("config", function()
                cacher.register_buffer(
                  bufnr,
                  { n_query = 10, }
                )
              end, nil)
            end,
            desc = "Register buffer for VectorCode",
          }
        )
      end
    }
  )
end

if USING_OLLAMA then
  notif_data = {}

  table.insert(
    ai_plugins,
    {
      'chr0n1x/cmp-ai',
      -- 'tzachar/cmp-ai',
      dependencies = 'nvim-lua/plenary.nvim',
      config = function()
        if OLLAMA_MODEL_NOT_PRESENT then
          vim.notify(
            "Ollama CMP Config error for model " .. OLLAMA_DEFAULT_MODEL .. " (model does not exist)",
            vim.log.levels.WARN,
            setup_notification_cfg
          )
          return
        end

        local cmp_ai = require('cmp_ai.config')
        local title = "Ollama-CMP"
        local msg = "querying ollama " .. OLLAMA_DEFAULT_MODEL

        -- https://github.com/rcarriga/nvim-notify/issues/71
        local spinner_frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }

        local function update_spinner(notif_data)
          local new_spinner = (notif_data.spinner + 1) % #spinner_frames
          notif_data.spinner = new_spinner

          if notif_data.notification == nil then
            return
          end

          notif_data.notification = vim.notify(
            msg, nil,
            {
              hide_from_history = true,
              icon = spinner_frames[new_spinner],
              replace = notif_data.notification,
            }
          )

          vim.defer_fn(function() update_spinner(notif_data) end, 256)
        end

        local start_notification = function()
          notif_data.spinner = 1
          notif_data.notification = vim.notify(
            msg,
            vim.log.levels.INFO,
            {
              title = title,
              icon = spinner_frames[1],
              timeout = false,
              hide_from_history = true,
            }
          )
          require('plenary.async').run(function() update_spinner(notif_data) end)
        end

        cmp_ai:setup({
          max_lines = 50,
          provider = 'Ollama',
          provider_options = {
            model = OLLAMA_DEFAULT_MODEL,
            prompt = function(lines_before, lines_after)
              -- You may include filetype and/or other project-wise context in this string as well.
              -- Consult model documentation in case there are special tokens for this.
              return "<|fim_prefix|>" .. lines_before .. "<|fim_suffix|>" .. lines_after .. "<|fim_middle|>"
            end,
          },
          notify = true,
          notify_callback = {
            on_start = start_notification,
            on_end = function ()
              vim.notify(
                msg, vim.log.levels.INFO,
                {
                  title = title,
                  timeout= 2000,
                  hide_from_history=false,
                  icon = "",
                  replace = notif_data.notification,
                }
              )

              notif_data.notification = nil
            end,
          },
          run_on_every_keystroke = false,
        })


        vim.notify(
          'started cmp with Ollama model: ' .. OLLAMA_DEFAULT_MODEL,
          vim.log.levels.INFO,
          setup_notification_cfg
        )
      end
    }
  )
end

return ai_plugins
