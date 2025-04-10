IN_PERF_MODE = os.getenv("NVIM_LAZY_N_LITE") == "true"
DISABLED_FOR_PERF = not IN_PERF_MODE

require('colors')
require('base-settings')
require('key-bindings')

require('config.lazy')

require('autocmds')
