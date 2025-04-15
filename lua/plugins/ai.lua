if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

require('../util/shell')
local task_notifications = require('../util/task_notifications')

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

if OLLAMA_ENABLED then
  cc_strats.inline.adapter = OLLAMA_ADAPTER_NAME
end
if OPENWEBUI_ENABLED then
  cc_strats.chat.adapter = OPENWEBUI_ADAPTER_NAME
end

-- starting configuration here, above are just general flags

local ai_plugins = {
  {
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

      local statusmsg = 'codecompanion AI adapter(s) configured:\n\n'

      if OPENWEBUI_ENABLED then
        statusmsg = statusmsg .. '> ' .. OPENWEBUI_MODEL .. ' via ' ..
          OPENWEBUI_URL .. ' (' .. OPENWEBUI_ADAPTER_NAME .. ') \n'
      end
      if OLLAMA_ENABLED then
        statusmsg = statusmsg .. '> ' .. OLLAMA_MODEL .. ' via ' ..
          OLLAMA_URL .. ' (' .. OLLAMA_ADAPTER_NAME .. ') \n'
      end
      statusmsg = statusmsg .. "\n(cmp-ai is separate)"

      if OLLAMA_ENABLED or OPENWEBUI_ENABLED then
        vim.notify(statusmsg, vim.log.levels.INFO, setup_notification_cfg)
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
    local task_name = "VectorCoderizing Codebase"
    local msg = "running `vectorcode vectorise` in " .. partial_glob
    task_notifications.start(task_name, msg)
    vim.fn.jobstart(
      'vectorcode vectorise ' .. file_glob,
      { on_exit = function() task_notifications.clear(task_name) end }
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
        { '<leader>v', ':VectorCode register<CR>', desc = 'VectorCode register' },
        { '<leader>vv', vectorise_codebase, desc = 'vectorise current codebase.' },
      },

      config = function ()
        vim.api.nvim_create_autocmd(
          'LspAttach',
          {
            callback = function()
              local cacher = require("vectorcode.config").get_cacher_backend()
              local bufnr = vim.api.nvim_get_current_buf()
              cacher.async_check("config", function()
                cacher.register_buffer(bufnr, { n_query = 10, })
              end, nil)
            end,
            desc = "Register buffer for VectorCode",
          }
        )
      end
    }
  )
end

if OLLAMA_ENABLED and OLLAMA_MODEL_PRESENT then
  table.insert(
    ai_plugins,
    {
      -- 'tzachar/cmp-ai',
      'chr0n1x/cmp-ai',
      branch = "dev",
      dependencies = 'nvim-lua/plenary.nvim',
      config = function()
        if OLLAMA_MODEL_NOT_PRESENT then
          vim.notify(
            "Ollama CMP Config error for model " .. OLLAMA_MODEL .. " (model does not exist)",
            vim.log.levels.WARN,
            setup_notification_cfg
          )
          return
        end

        local cmp_ai = require('cmp_ai.config')
        -- local task_name = "Ollama-CMP"
        -- local msg = "querying ollama " .. OLLAMA_MODEL
        -- local start_notification = function()
        --   task_notifications.clear(task_name, vim.log.levels.WARN)
        --   task_notifications.start(task_name, msg)
        -- end

        print('here')

        cmp_ai:setup({
          max_lines = 8, -- HOLY MOLY CAN BAD THINGS HAPPEN WHEN THIS IS TOO MUCH
          provider = 'Ollama',
          provider_options = {
            model = OLLAMA_MODEL,
            prompt = function(lines_before, lines_after)
              -- You may include filetype and/or other project-wise context in this string as well.
              -- Consult model documentation in case there are special tokens for this.
              return "<|fim_prefix|>" .. lines_before .. "<|fim_suffix|>" .. lines_after .. "<|fim_middle|>"
            end,
          },
          notify = true,
          notify_callback = {
            -- on_start = start_notification,
            on_start = function ()
  print('onstart')
              local conf = require('lualine').get_config()
              conf.sections.lualine_c = {
                {
                  function ()
                    local spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
                    -- TODO: IWANNA MAKE THIS FAST AF BOI
                    return  "🦙 " .. spinner[os.date('%S') % #spinner + 1] .. " " .. OLLAMA_MODEL
                  end
                }
              }
              require('lualine').setup(conf)
            end,

            -- on_end = function () task_notifications.clear(task_name) end,
            on_end = function ()
  print('onend')
              local conf = require('lualine').get_config()
              conf.sections.lualine_c = {
                { function () return  "🦙 ✓ " .. OLLAMA_MODEL end }
              }
              require('lualine').setup(conf)
            end,
          },
          -- notifications cannot keep up when this is set to true
          -- HELL - they can barely keep up now
          run_on_every_keystroke = false,

          -- TODO: EXPERIMENTAL
          max_timeout_seconds = '8',
          cancel_existing_completions = true,
          log_errors = false,
        })

        vim.notify(
          'started cmp with Ollama model: ' .. OLLAMA_MODEL,
          vim.log.levels.INFO,
          setup_notification_cfg
        )
      end
    }
  )
end

return ai_plugins
