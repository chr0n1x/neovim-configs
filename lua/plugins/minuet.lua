if IN_PERF_MODE then return {} end
-- only run this with ollama, just easier for now
if OLLAMA_NVIM_DISABLED then return {} end

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
    -- hacky solution
    local prompt_message = "The following is a FIM prompt, so you are given a code snippet prefix and a suffix. Before all of that you may receive some files from a RAG database with relevant code snippets. Only respond with what you think comes next, nothing else. If you cannot help, simply reply with '🤖 - start/continue typing!'\n"

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
  lazy = true,
  dependencies = {
    { 'nvim-lua/plenary.nvim' },
  },
  config = function()
    require('minuet').setup(config)

    local statusmsg = "💃🤝🦙 minuet-ai + ollama running\n"
    statusmsg = statusmsg .. '✅ ' .. OLLAMA_MODEL .. ' via ' .. OLLAMA_URL

    vim.notify(statusmsg, vim.log.levels.INFO, {
      title = "💃 Minuet-AI",
      style = "minimal",
      timeout = 1000,
    })
  end,
}
