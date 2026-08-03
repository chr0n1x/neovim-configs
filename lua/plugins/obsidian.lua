return {
  "obsidian-nvim/obsidian.nvim",
  version = "*", -- use latest release, remove to use latest commit
  opts = {
    legacy_commands = false,
    workspaces = {
      {
        name = "personal",
        path = os.getenv("OBSIDIAN_VAULT_PATH") or "~/obsidian/vault",
      },
    },
  },
}
