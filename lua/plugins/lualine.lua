local deps = {
  "nvim-web-devicons",
}

-- Static working glyph shared with the agent overview (harness-decorators.agent-display), used by
-- the session slot and lsp_status so nothing in the statusline animates.
local spinner = require("harness-decorators.agent-display").spinner or { "●" }

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
      -- The iceberg_dark theme only defines sections a/b/c, so lualine's x/y slots would otherwise
      -- render transparent (no section fill) and the session + agents components would visually merge
      -- into one blob. Give each right-hand slot its own distinct bg (from the same theme palette:
      -- #2e313f is section b's bg, #0f1117 is section c's) so lualine can draw a real section
      -- boundary between them.
      section_separators = { left = "", right = "" },
      -- Global statusline so it stays visible while a float has focus.
      globalstatus = true,
    }

    -- Custom component: show the active harness's pinned session slug or spinner. The display logic lives in
    -- harness-decorators.session_component (a plain module function) so it is unit-testable
    -- without a live statusline - see tests/lualine_spec.lua.
    table.insert(opts.sections.lualine_x, {
      function()
        return require("harness-decorators").session_component(spinner_frame)
      end,
      color = { fg = "#c6c8d1", bg = "#2e313f" },
      padding = { left = 1, right = 1 },
    })

    -- Agent overview: a SINGLE section summarizing the backgrounded (non-active) live agents as
    -- "<dot> N agents". The poll/diff/timer lives in harness-decorators.agent-display (a plain module)
    -- so it is unit-testable without a live statusline - see tests/agent_display_spec.lua. It redraws
    -- only when an agent's state changes.
    table.insert(opts.sections.lualine_y, 1, {
      function()
        return require("harness-decorators.agent-display").component()
      end,
      color = { fg = "#c6c8d1", bg = "#0f1117" },
      padding = { left = 1, right = 1 },
    })

    -- Start the poll timer here where the event loop is ready,
    -- and define the summary status-dot highlight groups (working is blue, idle is green,
    -- unknown is a dim ring). The setup is scheduled so it runs after lualine + the theme have
    -- finished defining their statusline groups. A ColorScheme switch re-runs it (see
    -- harness-decorators/init.lua).
    pcall(function()
      local display = require("harness-decorators.agent-display")
      display.start_timer()
      vim.schedule(display.setup_highlights)
    end)
  end,
}
