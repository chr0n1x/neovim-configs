OLLAMA_NVIM_DISABLED = (os.getenv("OLLAMA_NVIM_DISABLED") or "" == "true")

OLLAMA_URL = os.getenv("OLLAMA_HOST") or "http://0.0.0.0:11434"

-- TODO: HACK
local pieces = vim.split(vim.split(OLLAMA_URL, ":")[2], "/")
local domain = pieces[#pieces]
if domain == '0.0.0.0' or domain == '127.0.1' then
    OLLAMA_DOMAIN = "localhost"
else
    OLLAMA_DOMAIN = domain
end

OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY") or ""
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or 'hf.co/sweepai/sweep-next-edit-1.5B:latest'

-- conditionally do this if OLLAMA_MODEL is not empty
if OLLAMA_MODEL ~= "" then
  local model_name_pieces = vim.split(OLLAMA_MODEL, "/")
  OLLAMA_MODEL_SHORT = model_name_pieces[#model_name_pieces]
end

-- local exit = os.execute('ollama ls | grep ' .. OLLAMA_MODEL) / 256
-- OLLAMA_MODEL_NOT_PRESENT = (exit == 1)
-- OLLAMA_MODEL_PRESENT = not OLLAMA_MODEL_NOT_PRESENT
