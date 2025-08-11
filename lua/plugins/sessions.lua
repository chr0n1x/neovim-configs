return {
  lazy = false,
  'jedrzejboczar/possession.nvim',
  dependencies = {
    'nvim-lua/plenary.nvim'
  },
  opts = {
    autoload = "last",
    autosave = {
      cwd = true,
      current = true,
      on_load = true,
      on_quit = true,
    },
  },
  keys = {
    { "<leader>sl", ":PossessionListCwd<CR>", desc = "📌 Show cwd session." },
    { "<leader>s<CR>", ":PossessionSave<CR>", desc = "📌 Save current session" },
  },
}
