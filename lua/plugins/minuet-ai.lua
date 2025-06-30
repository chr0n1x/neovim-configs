if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED then return {} end

return {
  'milanglacier/minuet-ai.nvim',
  lazy = false,
  dependencies = {
    { 'nvim-lua/plenary.nvim' },
  },
  config = function()
    require('minuet').setup {
      notify = 'warn',

      provider = 'openai_fim_compatible',
      n_completions = 2,
      context_window = 256,
      provider_options = {
        openai_fim_compatible = {
          api_key = 'TERM',
          name = 'Ollama',
          end_point = OLLAMA_URL .. '/v1/completions',
          model = OLLAMA_MODEL,
          optional = {
            max_tokens = 16,
            top_p = 0.95,
          },
        },
      },

      -- settings for inline code preview
      virtualtext = {
        auto_trigger_ft = { '*' },
        keymap = {
          accept = '<leader><tab><tab><enter>',
          accept_line = '<leader><tab><enter>',
          prev = '<leader><tab>k',
          next = '<leader><tab>j',
          dismiss = '<leader><tab>l',
        },
      }

    }
  end,
}
