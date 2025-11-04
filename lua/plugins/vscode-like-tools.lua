return {
  {
    "danymat/neogen",
    config = function()
      require('neogen').setup({
        languages = {
          ['ts'] ='typescript',
          ['tsx'] ='typescriptreact',
        }
      })
    end,
    -- Uncomment next line if you want to follow only stable versions
    -- version = "*"
  }
}
