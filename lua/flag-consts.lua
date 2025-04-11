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
OPENWEBUI_DISABLED = (
  OPENWEBUI_JWT == "" or OPENWEBUI_JWT == nil or
  OPENWEBUI_URL == "" or OPENWEBUI_URL == nil
)
OPENWEBUI_ENABLED = not OPENWEBUI_DISABLED

-- ollama
OLLAMA_URL = os.getenv("OLLAMA_HOST")
OLLAMA_DISABLED = OLLAMA_URL == "" or OLLAMA_URL == nil
OLLAMA_ENABLED = not OLLAMA_DISABLED

DEFAULT_AI_ADAPTER = "ollama"
if OPENWEBUI_ENABLED then
  DEFAULT_AI_ADAPTER = "openwebui"
end
