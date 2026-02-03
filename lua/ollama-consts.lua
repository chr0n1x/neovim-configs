OLLAMA_NVIM_DISABLED = (os.getenv("OLLAMA_NVIM_DISABLED") or "" == "true")

OLLAMA_URL = os.getenv("OLLAMA_HOST") or "http://0.0.0.0:11434"
OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY") or ""
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or 'qwen2.5-coder:7b-base-q6_K' -- 7b-base is Q4
-- local exit = os.execute('ollama ls | grep ' .. OLLAMA_MODEL) / 256
-- OLLAMA_MODEL_NOT_PRESENT = (exit == 1)
-- OLLAMA_MODEL_PRESENT = not OLLAMA_MODEL_NOT_PRESENT
