if IN_PERF_MODE then return {} end
-- only run this with ollama, just easier for now
if OLLAMA_DISABLED then return {} end

local config = {
  notify = 'warn',

  provider = 'openai_fim_compatible',
  n_completions = 1,
  context_window = 32768,
  provider_options = {
    openai_fim_compatible = {
      api_key = 'TERM',
      name = '🦙',
      end_point = OLLAMA_URL .. '/v1/completions',
      model = OLLAMA_MODEL,
      optional = {
        max_tokens = 128,
        top_p = 0.95,
      },
    },
  },

  -- settings for inline code preview
  virtualtext = {
    auto_trigger_ft = { '*' },
    keymap = {
      accept = '<leader><tab><tab>',
      accept_line = '<leader><tab>',
      prev = '<leader><tab>k',
      next = '<leader><tab>j',
      dismiss = '<leader><tab>l',
    },
  }
}


config.provider_options.openai_fim_compatible.template = {
  suffix = false,
  prompt = function(pref, suff, _)
    local prompt_message = "The following is a FIM prompt. Only respond with the FIM response, nothing else.\n"

    local has_vc, vectorcode_config = pcall(require, 'vectorcode.config')
    local vectorcode_cacher = nil
    if has_vc then
      vectorcode_cacher = vectorcode_config.get_cacher_backend()
    end
    if VECTORCODE_INSTALLED and vectorcode_cacher ~= nil then
      local cache_result = vectorcode_cacher.query_from_cache(0)
      for _, file in ipairs(cache_result) do
        prompt_message = prompt_message .. "<|file_sep|>" .. file.path .. "\n" .. file.document
      end
    end

    return prompt_message
      .. "<|fim_prefix|>"
      .. pref
      .. "<|fim_suffix|>"
      .. suff
      .. "<|fim_middle|>"
  end,
}

return {
  'milanglacier/minuet-ai.nvim',
  lazy = false,
  dependencies = {
    { 'nvim-lua/plenary.nvim' },
  },
  config = function()
    require('minuet').setup(config)

    local statusmsg = "💃🤝🦙 minuet-ai + ollama running\n"
    statusmsg = statusmsg .. '✅ ' .. OLLAMA_MODEL .. ' via ' .. OLLAMA_URL
    if VECTORCODE_INSTALLED then
      statusmsg = statusmsg .. '\n' .. '✅ vectorcode RAG'
    end

    vim.notify(statusmsg, vim.log.levels.INFO, {
      title = "💃 Minuet-AI",
      style = "minimal",
      timeout = 1000,
    })
  end,
}
