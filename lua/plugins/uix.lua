-- UI and UX plugins: notifications, statusline, which-key, etc.
local uix_plugins = {
  {
    "rcarriga/nvim-notify",
    priority = 1001,
    lazy = false,
    config = function()
      vim.notify = require("notify")
      vim.notify.setup({
        top_down = false,
        background_colour = "#434C5E",
      })
    end,
    keys = {
      { "<leader>eh", ':lua require("notify").dismiss()<CR>', desc = "Clear notifications." },
      { "<leader>e", ":Telescope notify<CR>", desc = "View notifications in Telescope." },
    },
  },

  -- I hate the notification plugins in this thing w/ a passion
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      dashboard = {
        enabled = true,
        -- Use the awesome preset for a minimal, fast dashboard.
        preset = {
          header = [[
░░░░░░░█▐▓▓░████▄▄▄█▀▄▓▓▓▌█
░░░░░▄█▌▀▄▓▓▄▄▄▄▀▀▀▄▓▓▓▓▓▌█
░░░▄█▀▀▄▓█▓▓▓▓▓▓▓▓▓▓▓▓▀░▓▌█
░░█▀▄▓▓▓███▓▓▓███▓▓▓▄░░▄▓▐█▌
░█▌▓▓▓▀▀▓▓▓▓███▓▓▓▓▓▓▓▄▀▓▓▐█
▐█▐██▐░▄▓▓▓▓▓▀▄░▀▓▓▓▓▓▓▓▓▓▌█▌
█▌███▓▓▓▓▓▓▓▓▐░░▄▓▓███▓▓▓▄▀▐█
█▐█▓▀░░▀▓▓▓▓▓▓▓▓▓██████▓▓▓▓▐█
▌▓▄▌▀░▀░▐▀█▄▓▓██████████▓▓▓▌█▌
▌▓▓▓▄▄▀▀▓▓▓▀▓▓▓▓▓▓▓▓█▓█▓█▓▓▌█▌
█▐▓▓▓▓▓▓▄▄▄▓▓▓▓▓▓█▓█▓█▓█▓▓▓▐█
Forever MoonJanglin'
]],
        },
      },
      indent = { enabled = DISABLED_IF_IN_PERF_MODE },
      scope = { enabled = true },
      statuscolumn = { enabled = DISABLED_IF_IN_PERF_MODE },
      layout = { enabled = true },
      win = { enabled = DISABLED_IF_IN_PERF_MODE },
    },
  },

  {
    "tris203/precognition.nvim",
    opts = {
      startVisible = false,
      showBlankVirtLine = false,
      highlightColor = { link = "LineNr" },
      gutterHints = {
        G = { text = "G", prio = 10 },
        gg = { text = "gg", prio = 9 },
        PrevParagraph = { text = "{", prio = 8 },
        NextParagraph = { text = "}", prio = 8 },
      },
    },
    keys = {
      { "<leader>P", ':lua require("precognition").toggle()<CR>', desc = "toggle precognition" },
    },
  },

  {
    "m4xshen/hardtime.nvim",
    dependencies = { "MunifTanjim/nui.nvim" },
    config = function()
      -- Im too weenie hut juniors for this
      require("hardtime").setup({
        restriction_mode = "hint",
        -- REALLY too weenie hut juniors for this
        disable_mouse = false,
        callback = function(text)
          vim.notify(text, vim.log.levels.WARN, { render = "compact" })
        end,
      })
    end,
  },

  -- color schemes; I'm conflicted
  {
    "shaunsingh/nord.nvim",
    lazy = false,
    init = function()
      vim.g.nord_contrast = false
      vim.g.nord_borders = false
      vim.g.nord_bold = false
      vim.g.nord_italic = false
      vim.g.nord_disable_background = true
      vim.g.nord_uniform_diff_background = false
      require("nord").set()
    end,
  },

  {
    "chrisgrieser/nvim-origami",
    event = "VeryLazy",
    opts = {
      -- disabled: its async vim.lsp.foldclose races with edits and throws
      -- E490 (No fold found) in the scheduled callback
      autoFold = { enabled = false },
      foldtext = {
        enabled = true,
        padding = {
          width = 2,
        },
      },
      foldKeymaps = {
        setup = false,
      },
    },
    init = function()
      vim.opt.foldlevel = 99
      vim.opt.foldlevelstart = 99
      vim.api.nvim_set_keymap(
        "n",
        "zc",
        ':lua require("origami").caret()<CR>',
        { noremap = true, desc = "Close fold (better if lsp on)." }
      )
      vim.api.nvim_set_keymap(
        "n",
        "zo",
        ':lua require("origami").dollar()<CR>',
        { noremap = true, desc = "Open fold." }
      )
    end,
  },
}

if not IN_PERF_MODE then
  table.insert(
    uix_plugins,
    -- initially did not like this, but very useful for REALLY big screens
    {
      "sphamba/smear-cursor.nvim",
      opts = {
        cursor_color = "#AAD0E8",
        stiffness = 0.5,
        trailing_stiffness = 0.3,
        trailing_exponent = 5,
        damping = 0.6,
      },
    }
  )

  table.insert(uix_plugins, {
    dependencies = {
      "stevearc/conform.nvim",
    },
    opts = {
      filetypes = { "markdown", "md" },
    },
    "noisesfromspace/touchup.nvim",
  })

  -- based on https://github.com/MeanderingProgrammer/render-markdown.nvim/discussions/548
  table.insert(uix_plugins, {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "shaunsingh/nord.nvim" },
    opts = {
      file_types = { "markdown", "md", "codecompanion" },
      render_modes = { "n", "no", "c", "t", "i", "ic" },
      code = {
        sign = false,
        border = "thin",
        position = "right",
        width = "block",
        above = "▁",
        below = "▔",
        language_left = "█",
        language_right = "█",
        language_border = "▁",
        left_pad = 1,
        right_pad = 1,
      },
      heading = {
        sign = false,
        width = "block",
        -- nord.nvim defines these with a dark fg on a colored bg.
        backgrounds = {
          "MiniStatuslineModeVisual",
          "MiniStatuslineModeCommand",
          "MiniStatuslineModeReplace",
          "MiniStatuslineModeNormal",
          "MiniStatuslineModeOther",
          "MiniStatuslineModeInsert",
        },
        left_pad = 1,
        right_pad = 0,
        position = "right",
        icons = function(ctx)
          return ("\u{e0be}\u{e0b8}"):rep(ctx.level) .. "\u{e0be}"
        end,
      },
    },
    config = function(_, opts)
      require("render-markdown").setup(opts)
      local function apply()
        local c = require("nord.colors")
        local hl = function(name, val)
          vim.api.nvim_set_hl(0, name, val)
        end
        local heads = { c.nord7_gui, c.nord15_gui, c.nord11_gui, c.nord9_gui, c.nord13_gui, c.nord4_gui }
        hl("RenderMarkdownCode", { bg = c.nord1_gui })
        hl("RenderMarkdownCodeBorder", { bg = c.nord2_gui })
        hl("RenderMarkdownCodeInline", { fg = c.nord8_gui, bg = c.nord1_gui })
        for i, color in ipairs(heads) do
          hl("RenderMarkdownH" .. i, { fg = color })
          hl("RenderMarkdownH" .. i .. "Bg", { fg = c.nord0_gui, bg = color })
          hl("@markup.heading." .. i, { fg = color, bold = true })
        end
        hl("@markup.heading", { fg = c.nord9_gui, bold = true })
        hl("@markup.strong", { fg = c.nord9_gui, bold = true })
        hl("@markup.italic", { fg = c.nord9_gui, italic = true })
        hl("@markup.list", { fg = c.nord14_gui })
        hl("@markup.raw", { fg = c.nord8_gui, bg = c.nord1_gui })
        hl("@markup.quote", { fg = c.nord15_gui, italic = true })
      end
      apply()
      vim.api.nvim_create_autocmd("ColorScheme", { callback = apply })
    end,
  })

  table.insert(uix_plugins, {
    "anuvyklack/windows.nvim",
    lazy = false,
    dependencies = {
      "anuvyklack/middleclass",
      "anuvyklack/animation.nvim",
    },
    init = function()
      vim.o.winwidth = 10
      vim.o.winminwidth = 10
      -- No automatic resizing; <leader><space> (key-bindings.lua) runs it on demand.
      require("windows").setup({ autowidth = { enable = false } })
    end,
  })
end

return uix_plugins
