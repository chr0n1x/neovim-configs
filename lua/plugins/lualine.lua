local deps = {
  "nvim-web-devicons",
}

if os.getenv("NVIM_MINUET_ENABLED") == "true" then
  table.insert(deps, { "milanglacier/minuet-ai.nvim", lazy = false })
end

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Timer-driven spinner frame for smooth animation.
local spinner_frame = spinner[1]

LUALINE_SECTIONS = {
  lualine_a = { "fileformat", "mode" },
  lualine_b = { "branch" },

  lualine_x = {},
  lualine_y = {
    "encoding",
    "filetype",
    {
      "lsp_status",
      icon = "", -- f013
      symbols = {
        -- Standard unicode symbols to cycle through for LSP progress:
        spinner = spinner,
        -- Standard unicode symbol for when LSP is done:
        done = "✓",
        -- Delimiter inserted between LSP names:
        separator = " ",
      },
      -- List of LSP names to ignore (e.g., `null-ls`):
      ignore_lsp = {},
    },
  },

  -- default - present
  -- lualine_z = {'location'}
}

return {
  "hoob3rt/lualine.nvim",
  lazy = false,
  priority = 1000,
  dependencies = deps,
  opts = function(_, opts)
    if opts == nil then
      opts = {}
    end

    opts.sections = LUALINE_SECTIONS

    opts.options = {
      icons_enabled = true,
      theme = "iceberg_dark",
      component_separators = { "|", "|" },
    }

    -- Start spinner timer inside opts() where the event loop is ready.
    local frame_idx = 1
    local t = vim.uv.new_timer()
    if t then
      t:start(
        0,
        120,
        vim.schedule_wrap(function()
          spinner_frame = spinner[frame_idx]
          frame_idx = (frame_idx % #spinner) + 1
          pcall(vim.cmd.statusline)
        end)
      )
    end

    -- Custom component: show pinned Claude session slug or spinner.
    table.insert(opts.sections.lualine_x, {
      function()
        local ok, decorators = pcall(require, "claude-decorators")
        if not ok then
          return ""
        end
        local path = decorators.get_pinned_path()
        if not path then
          -- No pin yet — show spinner.
          return "🤖 " .. spinner_frame
        end
        local name = path:match("([^/]+)%.jsonl$")
        if not name then
          return ""
        end
        return "🤖 " .. name
      end,
      padding = { left = 1, right = 1 },
    })

    if os.getenv("NVIM_MINUET_ENABLED") == "true" then
      table.insert(opts.sections.lualine_x, {
        require("minuet.lualine"),
        -- the follwing is the default configuration
        -- the name displayed in the lualine. Set to "provider", "model" or "both"
        -- display_name = 'both',
        -- separator between provider and model name for option "both"
        -- provider_model_separator = ':',
        -- whether show display_name when no completion requests are active
        -- display_on_idle = false,
      })
    end
  end,
}
