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
    local stderr = {}
    local stdout = {}
    vim.fn.jobstart(
      'vectorcode vectorise ' .. file_glob,
      {
        on_stdout = function(chanid, data, name)
          table.insert(stdout, { chanid = chanid, data = data, name = name })
        end,
        on_stderr = function(chanid, data, name)
          table.insert(stderr, { chanid = chanid, data = data, name = name })
        end,
        on_exit = function()
          task_notifications.clear(task_name)

          local serialize_stdtxt = function(tbl)
            local out = ""
            for _, entry in ipairs(tbl) do
              for _, txt in ipairs(entry.data) do
                out = out .. '\n' .. txt
              end
            end
            return out
          end

          vim.notify("stdout: " .. serialize_stdtxt(stdout), vim.log.levels.DEBUG, { title = "VectorCode 'vectorise' output" })
          vim.notify("stderr: " .. serialize_stdtxt(stderr), vim.log.levels.WARN, { title = "VectorCode 'vectorise' StdErr" })
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
        { '<leader>v', ':VectorCode register<CR>', desc = 'VectorCode register' },
        { '<leader>vv', vectorise_codebase, desc = 'vectorise current codebase.' },
      },
      opts = function()
        return {
          async_backend = "lsp",
          notify = true,
          on_setup = { lsp = false },
          n_query = 10,
          timeout_ms = -1,
          async_opts = {
            events = { "BufWritePost" },
            single_job = true,
            query_cb = require("vectorcode.utils").make_surrounding_lines_cb(40),
            debounce = -1,
            n_query = 30,
          },
        }
      end,

      config = function ()
        vim.api.nvim_create_autocmd(
          'LspAttach',
          {
            callback = function()
              local cacher = require("vectorcode.config").get_cacher_backend()
              local bufnr = vim.api.nvim_get_current_buf()
              cacher.async_check("config", function()
                cacher.register_buffer(bufnr, { n_query = 10, })
                -- local query_results = cacher.query_from_cache(0, {notify=true})
                -- vim.notify(query_results)
              end, nil)
            end,
            desc = "Register buffer for VectorCode",
          }
        )
      end,

      cmd = "VectorCode",
      cond = function()
        return vim.fn.executable("vectorcode") == 1
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

        cmp_ai:setup({
          max_lines = 8, -- HOLY MOLY CAN BAD THINGS HAPPEN WHEN THIS IS TOO MUCH
          provider = 'Ollama',
          provider_options = {
            model = OLLAMA_MODEL,
            prompt = function(lines_before, lines_after)
              -- You may include filetype and/or other project-wise context in this string as well.
              -- Consult model documentation in case there are special tokens for this.
              local default_prompt = "<|fim_prefix|>\n" .. lines_before .. "\n<|fim_suffix|>\n" .. lines_after .. "\n<|fim_middle|>"

              if not vectorcode_exists then
                return default_prompt
              end

              local cacher = require("vectorcode.config").get_cacher_backend()
              local bufnr = vim.api.nvim_get_current_buf()
              cacher.register_buffer(bufnr, {
                n_query = 5,
                single_job = true,
              })
              local query_results = cacher.query_from_cache(bufnr)

              if #query_results == 0 then
                vim.notify(
                  'vectorcode cache did not return any results for LLM prompt',
                  vim.log.levels.DEBUG
                )
                return default_prompt
              end

              for _, source in pairs(query_results) do
                -- This works for qwen2.5-coder.
                default_prompt = "<|file_sep|>"
                .. source.path
                .. "\n"
                .. source.document
                .. "\n"
                .. "<|file_sep|>"
                .. "\n\n"
                .. default_prompt
              end

              vim.notify(
                default_prompt,
                vim.log.levels.DEBUG,
                { title = 'LLM prompt w/ vectorcode RAG' }
              )

              return default_prompt
            end,
          },
          notify = true,
          notify_callback = {
            -- old notify style notifications
            -- on_start = start_notification,
            -- on_end = function () task_notifications.clear(task_name) end,

            on_start = function ()
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

            on_end = function ()
              local conf = require('lualine').get_config()
              conf.sections.lualine_c = {
                { function () return  "🦙 ✓ " .. OLLAMA_MODEL end }
              }
              require('lualine').setup(conf)
            end,
          },

          -- TODO: EXPERIMENTAL
          run_on_every_keystroke = true,
          async_prompting = true,
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
