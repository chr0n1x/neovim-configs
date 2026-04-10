local command = "claude"
local claude_cmd_env = os.getenv("CLAUDE_COMMAND")

vim.api.nvim_create_autocmd("ExitPre", {
  pattern = "*",
  callback = function()
    vim.cmd('silent! ClaudeCodeClose<CR>')
    vim.cmd('silent! ClaudeCodeStop<CR>')
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end,
})

-- agent99: CLAUDE_MODEL env var if set, else OLLAMA_MODEL
-- NOTE: make sure that the model can use tools
local model99 = os.getenv("CLAUDE_MODEL") or OLLAMA_MODEL
vim.fn.setenv("CLAUDE_CODE_TRACKING_ENABLED", "true")

if claude_cmd_env and claude_cmd_env ~= "" then
  command = claude_cmd_env
elseif OLLAMA_MODEL ~= "" then
  vim.fn.setenv("ANTHROPIC_BASE_URL", OLLAMA_URL)
  vim.fn.setenv("ANTHROPIC_API_KEY", "")
  vim.fn.setenv("ANTHROPIC_AUTH_TOKEN", "ollama")
  command = "claude --model " .. model99
end

-- I HAVE to be stupid, there has to be an easier way to do this
-- specifically written to go back to the previous window BECAUSE
-- we're using a floating terminal

local function valid_buf(win_id)
  local config = vim.api.nvim_win_get_config(win_id)
  local buf_info = vim.api.nvim_win_get_buf(win_id)
  local buf_name = vim.api.nvim_buf_get_name(buf_info)
  local terminal_win = vim.api.nvim_get_current_win()

  return not config.z and buf_name ~= "" and win_id ~= terminal_win
end

local function find_base_window(reverse)
  local wins = vim.api.nvim_list_wins()

  if reverse then
    for _, win_id in ipairs(wins) do
      if valid_buf(win_id) then
        vim.api.nvim_set_current_win(win_id)
        return
      end
    end
    return
  end

  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    if valid_buf(win_id) then
      vim.api.nvim_set_current_win(win_id)
      return
    end
  end
end

local set_prev_win = function() find_base_window(false) end

local set_next_win = function() find_base_window(true) end

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

      -- server - required to send ctx
      -- port_range = {        -- WebSocket server port range
      --  min = 10000,
      --  max = 65535,
      -- },
      auto_start = true,       -- Auto-start server on Neovim startup
      focus_after_send = true, -- after <leader>ca go to terminal
      log_level = "info",

      diff_opts = {
        layout = "vertical",
        open_in_new_tab = true,
        keep_terminal_focus = false,         -- If true, moves focus back to terminal after diff opens
        hide_terminal_in_new_tab = true,     -- works better personally w/ floating
        on_new_file_reject = "close_window", -- "keep_empty" or "close_window"
      },

      terminal = {
        provider = "auto",
        auto_close = true,

        snacks_win_opts = {
          position = "float",
          border = "rounded",
          footer_keys = true,
          fix_buf = true,
          resize = true,
          stack = true,
          start_insert = true,

          keys = {
            {
              "<Esc>",
              function(self)
                self:hide()
                vim.cmd(":redraw!")
              end,
              mode = "t",
              desc = "Hide"
            },

            {
              "<C-h>",
              function(self)
                set_prev_win()
                vim.cmd(":redraw!")
              end,
              mode = "t", desc = "⏮️"
            },
            {
              "<C-l>", function(self)
                set_next_win()
                vim.cmd(":redraw!")
              end,
              mode = "t", desc = "⏭️"
            },
          },

          -- TODO: make these...more relative
          row = 0.01,
          col = 0.58,
          width = 0.35,
          height = 0.9,
        },
      }
    },
    keys = {
      { "<leader>c", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
      -- { "<leader>c", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
      -- { "<leader>cf", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
      { "<leader>cr", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
      { "<leader>cc", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
      { "<leader>cm", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
      { "<leader>ca", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
      -- esc required to exit visual mode after going into terminal
      { "<leader>ca", "<cmd>ClaudeCodeSend<cr>; <esc>", mode = "v", desc = "Send to Claude" },
      {
        "<C-t>",
        "<cmd>ClaudeCodeTreeAdd<cr>",
        desc = "Add file",
        ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
      },
      -- Diff management
      { "<leader>cda", "<cmd>ClaudeCodeDiffAccept<cr>; redraw<cr>", desc = "Accept diff & redraw" },
      { "<leader>cdd", "<cmd>ClaudeCodeDiffDeny<cr>; redraw<cr>", desc = "Deny diff & redraw" },
    },
  },
}
