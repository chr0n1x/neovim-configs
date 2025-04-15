require('../util/shell')

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
-- NOTE: startup time might be better with 1B
-- 1080ti over proxmox pci passthrough to talos os is takes a few seconds for 4B
-- and 12B takes FOREVER, t/s is also not too good
OPENWEBUI_MODEL = os.getenv("OPEN_WEBUI_MODEL") or "gemma3:4B"
OPENWEBUI_DISABLED = (
  OPENWEBUI_JWT == "" or OPENWEBUI_JWT == nil or
  OPENWEBUI_URL == "" or OPENWEBUI_URL == nil
)
OPENWEBUI_ENABLED = not OPENWEBUI_DISABLED
OPENWEBUI_ADAPTER_NAME = "openwebui"

-- ollama
OLLAMA_URL = os.getenv("OLLAMA_HOST")
OLLAMA_API_KEY = os.getenv("OLLAMA_API_KEY") or ""
OLLAMA_DISABLED = OLLAMA_URL == "" or OLLAMA_URL == nil
OLLAMA_ENABLED = not OLLAMA_DISABLED
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL") or 'qwen2.5-coder:7b-base-q6_K'
local ok, out = pcall(
  RUN_SHELL_CMD, 'ollama ls | grep ' .. OLLAMA_MODEL
)
OLLAMA_MODEL_NOT_PRESENT = not ok or out == "" or out == nil
OLLAMA_MODEL_PRESENT = not OLLAMA_MODEL_NOT_PRESENT
OLLAMA_ADAPTER_NAME = "ollama"

DEFAULT_AI_ADAPTER = OLLAMA_ADAPTER_NAME
if OPENWEBUI_ENABLED then
  DEFAULT_AI_ADAPTER = OPENWEB_UI_ADAPTER_NAME
end
