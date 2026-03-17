local command = "claude"
local claude_cmd_env = os.getenv("CLAUDE_COMMAND")

-- agent99: CLAUDE_MODEL env var if set, else OLLAMA_MODEL
-- NOTE: make sure that the model can use tools
local model99 = os.getenv("CLAUDE_MODEL") or OLLAMA_MODEL

if claude_cmd_env and claude_cmd_env ~= "" then
  command = claude_cmd_env
elseif OLLAMA_MODEL ~= "" then
  vim.fn.setenv("ANTHROPIC_BASE_URL", OLLAMA_URL)
  vim.fn.setenv("ANTHROPIC_API_KEY", "")
  vim.fn.setenv("ANTHROPIC_AUTH_TOKEN", "ollama")
  command = "claude --model " .. model99
end

return {
  {
    "ThePrimeagen/99",
    config = function()
      local _99 = require("99")

      local cwd = vim.uv.cwd()
      local basename = vim.fs.basename(cwd)
      _99.setup({
        -- required for claude
        provider = _99.Providers.ClaudeCodeProvider,
        model = model99,
        tmp_dir = "./tmp",

        logger = {
          level = _99.DEBUG,
          path = "/tmp/" .. basename .. ".99.debug",
          print_on_error = true,
        },

        completion = {
          files = {
            -- enabled = true,
            -- max_file_size = 102400,     -- bytes, skip files larger than this
            -- max_files = 5000,            -- cap on total discovered files
            -- exclude = { ".env", ".env.*", "node_modules", ".git", ... },
          },
          source = "native",
        },

        -- do NOT change this for now
        md_files = {
          "AGENT.md",
        },
      })

      vim.keymap.set("n", "<leader>C", function()
        _99.visual()
      end, {noremap = true, desc = '99 Prompt to ' .. OLLAMA_MODEL_SHORT })
      vim.keymap.set("v", "<leader>C", function()
        _99.visual()
      end, {noremap = true, desc = 'Prompt in visual mode.' })

      --- if you have a request you dont want to make any changes, just cancel it
      vim.keymap.set("n", "<leader>Cx", function()
        _99.stop_all_requests()
      end, {noremap = true, desc = 'Stop all requests.' })

      vim.keymap.set("n", "<leader>Cs", function()
        _99.search()
      end, {noremap = true, desc = 'Perform search.' })
    end,
  },

  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    config = true,
    opts = {
      terminal_cmd = command,
      auto_start = false,
      terminal = {
        provider = "auto",
        auto_close = true,
        snacks_win_opts = {
          -- relative = "cursor",
          row = 0.01,
          col = 0.65,
          position = "float",
          width = 0.30,
          height = 0.9,
          border = "rounded",
          keys = {
            claude_hide = { "<Esc>", function(self) self:hide() end, mode = "t", desc = "Hide" },
            claude_close = { "<Shift><Esc>", "close", mode = "n", desc = "Close" },
          },
        },
      }
    },
    keys = {
      { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
      { "<leader>cc", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
      { "<leader>cf", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
      { "<leader>cr", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
      { "<leader>cC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
      { "<leader>cm", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
      { "<leader>cb", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
      { "<leader>cs", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
      {
        "<leader>cs",
        "<cmd>ClaudeCodeTreeAdd<cr>",
        desc = "Add file",
        ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
      },
      -- Diff management
      { "<leader>ca", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
      { "<leader>cd", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
    },
  },

  -- {
  --   "greggh/claude-code.nvim",
  --   dependencies = {
  --     "nvim-lua/plenary.nvim", -- Required for git operations
  --   },
  --   config = function()
  --     local settings = {
  --       command = command,
  --       window = {
  --         position = "vertical",
  --         float = {
  --           width = "25%",
  --           height = "85%",
  --           row = "5%",
  --           col = "70%",
  --           relative = "editor",  -- Relative to: "editor" or "cursor"
  --           border = "solid",   -- Border style: "none", "single", "double", "rounded", "solid", "shadow"
  --         },
  --       },
  --
  --       keymaps = {
  --         toggle = {
  --           normal = "<leader>An",    -- Normal mode keymap for toggling Claude Code, false to disable
  --           terminal = "<leader>At",  -- Terminal mode keymap for toggling Claude Code, false to disable
  --           variants = {
  --             continue = "<leader>A", -- Normal mode keymap for Claude Code with continue flag
  --             verbose = "<leader>AV", -- Normal mode keymap for Claude Code with verbose flag
  --           },
  --         },
  --         window_navigation = true, -- Enable window navigation keymaps (<C-h/j/k/l>)
  --         scrolling = true,         -- Enable scrolling keymaps (<C-f/b>) for page up/down
  --       }
  --     }
  --
  --     require("claude-code").setup(settings)
  --   end
  -- }

}
