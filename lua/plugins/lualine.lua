local deps = {
  "nvim-web-devicons",
}

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

    -- Custom component: show pinned Claude session slug or spinner. The display logic lives in
    -- harness-decorators.session_component (a plain module function) so it is unit-testable
    -- without a live statusline - see tests/lualine_spec.lua.
    table.insert(opts.sections.lualine_x, {
      function()
        local ok, decorators = pcall(require, "harness-decorators")
        if not ok then
          return ""
        end
        return decorators.session_component(spinner_frame)
      end,
      padding = { left = 1, right = 1 },
    })
  end,
}
