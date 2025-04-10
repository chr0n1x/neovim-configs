if IN_PERF_MODE then return {} end

return {
  "Davidyz/VectorCode",
  version = "*",
  build = "uvenv upgrade vectorcode",
  dependencies = { "nvim-lua/plenary.nvim" },
}
