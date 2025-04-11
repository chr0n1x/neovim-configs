if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

local run_shell_cmd = function(shcmd)
  local handle = io.popen(shcmd)
  if handle == nil then return end

  local result = handle:read("*a")
  handle:close()

  return result
end

local ollama_model = 'qwen2.5-coder:7b-base-q6_K'
local vectorcode_exists = pcall(run_shell_cmd, 'which vectorcode')
local ollama_qwen_pulled = pcall(run_shell_cmd, 'ollama ls | grep ' .. ollama_model)

local deps = {
  "nvim-lua/plenary.nvim",
  "nvim-treesitter/nvim-treesitter",
}
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
          vim.log.levels.INFO
        )
        return
      end

      if OLLAMA_ENABLED then
        vim.notify(
          'codecompanion adapter ' ..
            DEFAULT_AI_ADAPTER ..
            ' AI via ' .. OLLAMA_URL ..
            ' enabled',
          vim.log.levels.INFO
        )
      end
    end
  },
}

if vectorcode_exists then
  local vectorise_codebase = function ()
    local ext = vim.fn.expand('%:e')
    local partial_glob = vim.fn.expand('%:h') .. "/**/*." .. ext
    if #ext == 0 then
      vim.notify("Not Vectorising, no files found in " .. partial_glob, vim.log.levels.ERROR)
      return
    end

    local file_glob = vim.fn.expand('%:p:h') .. "/**/*." .. ext
    vim.fn.jobstart(
      'vectorcode vectorise ' .. file_glob,
      {
        on_exit = function()
          vim.notify("vectorised code in " .. partial_glob)
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

if DEFAULT_AI_ADAPTER == "ollama" and ollama_qwen_pulled then
  table.insert(
    ai_plugins,
    {
      'tzachar/cmp-ai',
      dependencies = 'nvim-lua/plenary.nvim',
      config = function()
        local cmp_ai = require('cmp_ai.config')

        cmp_ai:setup({
          max_lines = 50,
          provider = 'Ollama',
          provider_options = {
            model = ollama_model,
            prompt = function(lines_before, lines_after)
              -- You may include filetype and/or other project-wise context in this string as well.
              -- Consult model documentation in case there are special tokens for this.
              return "<|fim_prefix|>" .. lines_before .. "<|fim_suffix|>" .. lines_after .. "<|fim_middle|>"
            end,
          },
          notify = true,
          notify_callback = function(msg)
            vim.notify("Ollama-CMP: " .. msg)
          end,
          run_on_every_keystroke = false,
        })

        vim.notify('started cmp with Ollama model: ' .. ollama_model, vim.log.levels.INFO)
      end
    }
  )
end

return ai_plugins
