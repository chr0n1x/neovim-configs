local nmap = vim.api.nvim_set_keymap

nmap("n", "<leader><S-tab>", ":Neotree toggle<CR>", { noremap = true, desc = "Neotree toggle." })
nmap("n", "<leader><tab>", ":Neotree reveal<CR>", { noremap = true, desc = "Neotree reveal file for buff." })

return {
  "nvim-neo-tree/neo-tree.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
  },
  lazy = false,
  opts = {
    filesystem = {
      bind_to_cwd = true,
      filtered_items = {
        hide_dotfiles = false,
      },
    },
    enable_diagnostics = false,
    popup_border_style = "",
    window = {
      -- I hate this thing with a passion
      mappings = {
        ["/"] = "noop",
        ["O"] = "expand_all_nodes",
      },
    },
  },
}
