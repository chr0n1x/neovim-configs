-- called with no other arguments (i.e.: command was just `nvim`)
-- go right into find-files
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.cmd([[au VimEnter * AnyFoldActivate]])
  end,
})

-- Initialize Claude Code wrappers after plugins are loaded (live)
vim.api.nvim_create_autocmd("User", {
  pattern = "LazyDone",
  callback = function()
    local mod = require("harness-decorators")
    if mod then
      mod.setup()
    end

    -- Define harness title hl groups so they exist before any terminal opens.
    -- Re-defined on ColorScheme (see ai-harness.lua) to survive `hi clear`.
    require("harness-decorators.title").define_all()
  end,
})
