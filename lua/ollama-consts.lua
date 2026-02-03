OLLAMA_NVIM_DISABLED = (os.getenv("OLLAMA_NVIM_DISABLED") or "" == "true")

OLLAMA_URL = os.getenv("OLLAMA_HOST") or "http://0.0.0.0:11434"
OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY") or ""
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or 'hf.co/sweepai/sweep-next-edit-1.5B:latest'
-- local exit = os.execute('ollama ls | grep ' .. OLLAMA_MODEL) / 256
-- OLLAMA_MODEL_NOT_PRESENT = (exit == 1)
-- OLLAMA_MODEL_PRESENT = not OLLAMA_MODEL_NOT_PRESENT
