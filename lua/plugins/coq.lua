vim.g.coq_settings = {
  auto_start = true,
  clients = {
    tabnine = { enabled = false },
    snippets = {
      enabled = true,
      weight_adjust = 2,
    },
    lsp = {
      enabled = true,
      resolve_timeout = 2,
      weight_adjust = 1.75,
    },
    tree_sitter = {
      enabled = true,
      weight_adjust = 1.5,
    },
    buffers = { enabled = true }
  }
}

vim.api.nvim_command('COQnow --shut-up')
