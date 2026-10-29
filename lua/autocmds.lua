-- Define harness title hl groups after plugins are loaded so they exist before any
-- terminal opens. Re-defined on ColorScheme (see harness-decorators/init.lua) to survive `hi clear`.
vim.api.nvim_create_autocmd("User", {
  pattern = "LazyDone",
  callback = function()
    require("harness-decorators.title").define_all()
  end,
})
