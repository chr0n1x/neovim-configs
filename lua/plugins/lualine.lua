local deps = {
  "nvim-web-devicons",
}

-- The spinner frames are shared with the agent overview (harness-decorators.agent-display) so both
-- the session slot's waiting spinner and the working-state dot animate through the same list.
local ok_display, display_mod = pcall(require, "harness-decorators.agent-display")
local spinner = (ok_display and display_mod.spinner)
  or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

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
      -- The iceberg_dark theme only defines sections a/b/c, so lualine's x/y slots would otherwise
      -- render transparent (no section fill) and the session + agents components would visually merge
      -- into one blob. Give each right-hand slot its own distinct bg (from the same theme palette:
      -- #2e313f = b, #0f1117 = c) so lualine can draw a real section boundary between them.
      section_separators = { left = "", right = "" },
      -- One tabpage-wide statusline (laststatus=3) instead of per-window. Without this, focusing
      -- the floating harness terminal blanks its own statusline (lualine leaves floats a bare
      -- transparent line), which made the agent overview + session slots vanish exactly when you
      -- were looking at the agent. globalstatus keeps a single live line for the whole tabpage.
      globalstatus = true,
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
      -- Own section fill (theme only defines a/b/c). Distinct from the agents slot below so lualine
      -- draws a real boundary between them instead of merging the two into one transparent blob.
      color = { fg = "#c6c8d1", bg = "#2e313f" },
      padding = { left = 1, right = 1 },
    })

    -- Agent overview: a SINGLE section summarizing the backgrounded (non-active) live agents as
    -- "<dot> N agents". The poll/diff/timer lives in harness-decorators.agent-display (a plain module)
    -- so it is unit-testable without a live statusline - see tests/agent_display_spec.lua. It redraws
    -- only when an agent's state changes, plus the slow pulse while one is working.
    table.insert(opts.sections.lualine_y, 1, {
      function()
        local ok, display = pcall(require, "harness-decorators.agent-display")
        if not ok then
          return ""
        end
        return display.component()
      end,
      -- Own section fill, distinct from the session slot's #2e313f (theme's c color) so the two
      -- right-hand slots read as separate sections.
      color = { fg = "#c6c8d1", bg = "#0f1117" },
      padding = { left = 1, right = 1 },
    })

    -- Start the poll timer here where the event loop is ready (same place the spinner timer starts),
    -- and define the summary status-dot highlight groups (working = blue pulse, idle = green,
    -- unknown = dim ring). The setup is scheduled so it runs after lualine + the theme have finished
    -- defining their statusline groups. A ColorScheme switch re-runs it (see ai-harness.lua).
    pcall(function()
      local display = require("harness-decorators.agent-display")
      display.start_timer()
      vim.schedule(display.setup_highlights)
    end)
  end,
}
