-- called with no other arguments (i.e.: command was just `nvim`)
-- go right into find-files
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    vim.cmd [[au VimEnter * AnyFoldActivate]]
  end
})

-- Initialize Claude Code wrappers after plugins are loaded (live)
vim.api.nvim_create_autocmd('User', {
  pattern = 'LazyDone',
  callback = function()
    local mod = require('claude-decorators')
    if mod then mod.setup() end
  end,
})
