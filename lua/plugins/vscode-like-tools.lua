return {
  {
    "danymat/neogen",
    config = function()
      require("neogen").setup({
        languages = {
          ["ts"] = "typescript",
          ["tsx"] = "typescriptreact",
        },
      })
    end,
  },
}
