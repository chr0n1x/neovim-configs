if IN_PERF_MODE then return {} end
if OLLAMA_DISABLED and OPENWEBUI_DISABLED then return {} end
if VECTORCODE_NOT_INSTALLED then return {} end

local task_notifications = require('../util/task_notifications')

local vc_notification_cfg = { title = "VectorCode", render = "compact" }

local vectorise_codebase = function()
  local ext = vim.fn.expand('%:e')
  local partial_glob = vim.fn.expand('%:h') .. "/**/*." .. ext
  if #ext == 0 then
    vim.notify(
      "Not Vectorising, no files found in " .. partial_glob,
      vim.log.levels.ERROR,
      vc_notification_cfg
    )
    return
  end

  local file_glob = vim.fn.expand('%:p:h') .. "/**/*." .. ext
  local task_name = "VectorCoderizing Codebase"
  local msg = "running `vectorcode vectorise` in " .. partial_glob
  local stderr = {}
  local stdout = {}

  task_notifications.start(task_name, msg)
  vim.fn.jobstart(
    'vectorcode vectorise ' .. file_glob,
    {
      on_stdout = function(chanid, data, name)
        table.insert(stdout, { chanid = chanid, data = data, name = name })
      end,
      on_stderr = function(chanid, data, name)
        table.insert(stderr, { chanid = chanid, data = data, name = name })
      end,
      on_exit = function()
        task_notifications.clear(task_name)

        local serialize_stdtxt = function(tbl)
          local out = ""
          for _, entry in ipairs(tbl) do
            for _, txt in ipairs(entry.data) do
              out = out .. '\n' .. txt
            end
          end
          return out
        end

        vim.notify(
          "stdout: " .. serialize_stdtxt(stdout),
          vim.log.levels.DEBUG,
          { title = "VectorCode 'vectorise' output" }
        )
        vim.notify(
          "stderr: " .. serialize_stdtxt(stderr),
          vim.log.levels.WARN,
          { title = "VectorCode 'vectorise' StdErr" }
        )
      end
    }
  )
end

return {
  "Davidyz/VectorCode",
  lazy = false,
  build = "uvenv upgrade vectorcode",
  -- version = "*",
  dependencies = { "nvim-lua/plenary.nvim" },

  keys = {
    { '<leader>v', ':VectorCode register<CR>', desc = 'VectorCode register' },
    { '<leader>vv', vectorise_codebase, desc = 'vectorise current codebase.' },
  },
  opts = function()
    return {
      async_backend = "lsp",
      notify = true,
      on_setup = { lsp = false },
      n_query = 10,
      timeout_ms = -1,
      async_opts = {
        events = { "BufWritePost" },
        single_job = true,
        query_cb = require("vectorcode.utils").make_surrounding_lines_cb(40),
        debounce = -1,
        n_query = 30,
      },
    }
  end,

  config = function ()
    vim.api.nvim_create_autocmd(
      'LspAttach',
      {
        callback = function()
          local cacher = require("vectorcode.config").get_cacher_backend()
          local bufnr = vim.api.nvim_get_current_buf()
          cacher.async_check("config", function()
            cacher.register_buffer(bufnr, { n_query = 10, })
            -- local query_results = cacher.query_from_cache(0, {notify=true})
            -- vim.notify(query_results)
          end, nil)
        end,
        desc = "Register buffer for VectorCode",
      }
    )
  end,

  cmd = "VectorCode",
  -- cond = VECTORCODE_INSTALLED
}
