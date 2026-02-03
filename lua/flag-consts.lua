-- prevent a bunch of plugins from loading when on a machine like...
-- an rpi zero
IN_PERF_MODE = os.getenv("NVIM_LAZY_N_LITE") == "true"
DISABLED_IF_IN_PERF_MODE = not IN_PERF_MODE
