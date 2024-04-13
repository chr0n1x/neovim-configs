-- called with no other arguments (i.e.: command was just `nvim`)
-- go right into find-files
vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    vim.cmd [[au VimEnter * AnyFoldActivate]]

    require('lualine').setup()
    vim.cmd('COQnow')

    if vim.fn.argv(0) == '' then
      require('telescope.builtin').find_files()
    end
  end,
})

vim.api.nvim_create_autocmd('Bufenter', {
  callback = function()
    vim.cmd [[au Bufenter Makefile,Dockerfile set filetype=bash]]
  end,
})
