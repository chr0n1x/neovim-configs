-- Calls harness-decorators.setup at startup for the active harness.
local utils = require("harness-decorators.utils")
local harness = os.getenv("NVIM_LLM_HARNESS") or "claude"

if vim.tbl_contains(utils.list_harnesses(), harness) then
  require("harness-decorators").setup(harness)
end

return {}
