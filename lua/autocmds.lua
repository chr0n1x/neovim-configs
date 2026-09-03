-- called with no other arguments (i.e.: command was just `nvim`)
-- go right into find-files
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.cmd([[au VimEnter * AnyFoldActivate]])
  end,
})

-- Define harness title hl groups after plugins are loaded so they exist before any
-- terminal opens. Re-defined on ColorScheme (see ai-harness.lua) to survive `hi clear`.
vim.api.nvim_create_autocmd("User", {
  pattern = "LazyDone",
  callback = function()
    require("harness-decorators.title").define_all()
  end,
})
