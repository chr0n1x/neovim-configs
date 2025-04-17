if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end

-- notification things
local setup_notification_cfg = {
  title = "AI Plugin Setup",
  style = "minimal",
  timeout = 1000,
}

local lualine_update_ollama_progressing = function ()
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
end

local lualine_update_ollama_done = function ()
  local conf = require('lualine').get_config()
  conf.sections.lualine_c = {
    { function () return  "🦙 ✓ " .. OLLAMA_MODEL end }
  }
  require('lualine').setup(conf)
end

local prompt_constructor = function(lines_before, lines_after)
  -- You may include filetype and/or other project-wise context in this string as well.
  -- Consult model documentation in case there are special tokens for this.
  local default_prompt = "<|fim_prefix|>\n" .. lines_before .. "\n<|fim_suffix|>\n" .. lines_after .. "\n<|fim_middle|>"

  if VECTORCODE_NOT_INSTALLED then
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
end

local cmp_ai_opts = {
  max_lines = 8, -- HOLY MOLY CAN BAD THINGS HAPPEN WHEN THIS IS TOO MUCH
  provider = 'Ollama',
  provider_options = {
    model = OLLAMA_MODEL,
    prompt = prompt_constructor,
  },
  notify = true,
  notify_callback = {
    on_start = lualine_update_ollama_progressing,
    on_end = lualine_update_ollama_done,
  },
  -- TODO: EXPERIMENTAL
  run_on_every_keystroke = true,
  async_prompting = true,
  max_timeout_seconds = '8',
  cancel_existing_completions = true,
  log_errors = false,
}

return {
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
    cmp_ai:setup(cmp_ai_opts)

    vim.notify(
      'started cmp with Ollama model: ' .. OLLAMA_MODEL,
      vim.log.levels.INFO,
      setup_notification_cfg
    )
  end
}
