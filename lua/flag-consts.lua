-- prevent a bunch of plugins from loading when on a machine like...
-- an rpi zero
IN_PERF_MODE = os.getenv("NVIM_LAZY_N_LITE") == "true"
DISABLED_IF_IN_PERF_MODE = not IN_PERF_MODE

-- AI plugin load logic/flags
-- plugins usually not loaded when IN_PERF_MODE == true
-- defining here because multiple plugins depend on these

-- open webui
OPENWEBUI_URL = os.getenv("OPEN_WEBUI_URL")
OPENWEBUI_JWT = os.getenv("OPEN_WEBUI_JWT")
-- non-thinking model better for chatting
OPENWEBUI_MODEL = os.getenv("OPEN_WEBUI_MODEL") or "hf.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_XL"
OPENWEBUI_DISABLED = (
  OPENWEBUI_JWT == "" or OPENWEBUI_JWT == nil or
  OPENWEBUI_URL == "" or OPENWEBUI_URL == nil
)
OPENWEBUI_ENABLED = not OPENWEBUI_DISABLED
OPENWEBUI_ADAPTER_NAME = "openwebui"

-- ollama
OLLAMA_URL = os.getenv("OLLAMA_HOST") or "http://0.0.0.0:11434"
OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY") or ""
OLLAMA_NVIM_DISABLED = os.getenv("OLLAMA_NVIM_DISABLED") or ""
OLLAMA_DISABLED = OLLAMA_URL == "" or OLLAMA_URL == nil or OLLAMA_NVIM_DISABLED == "true"
OLLAMA_ENABLED = not OLLAMA_DISABLED
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or 'qwen2.5-coder:7b-base-q6_K' -- 7b-base is Q4
local exit = os.execute('ollama ls | grep ' .. OLLAMA_MODEL) / 256
OLLAMA_MODEL_NOT_PRESENT = (exit == 1)
OLLAMA_MODEL_PRESENT = not OLLAMA_MODEL_NOT_PRESENT
OLLAMA_ADAPTER_NAME = "ollama"

DEFAULT_AI_ADAPTER = OLLAMA_ADAPTER_NAME
if OPENWEBUI_ENABLED then
  DEFAULT_AI_ADAPTER = OPENWEBUI_ADAPTER_NAME
end

VECTORCODE_NOT_INSTALLED=(os.execute('which vectorcode') / 256) == 1
VECTORCODE_INSTALLED= not VECTORCODE_NOT_INSTALLED
