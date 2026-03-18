local command = "claude"
local claude_cmd_env = os.getenv("CLAUDE_COMMAND")

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

local set_prev_win = function()
  local win_ids = vim.api.nvim_list_wins()
  local terminal_win = vim.api.nvim_get_current_win()
  local prev_win_ix = win_ids[win_ids.length]
  for i, num in ipairs(win_ids) do
    if i ~= 1 and num == terminal_win then
      prev_win_ix = win_ids[i - 1]
    end
  end
  vim.api.nvim_set_current_win(prev_win_ix)
end

local set_next_win = function()
  local win_ids = vim.api.nvim_list_wins()
  local terminal_win = vim.api.nvim_get_current_win()
  local next_win_ix = win_ids[0]
  for i, num in ipairs(win_ids) do
    if i ~= #win_ids and num == terminal_win then
      next_win_ix = win_ids[i + 1]
    end
  end
  vim.api.nvim_set_current_win(next_win_ix)
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
          position = "float",
          border = "rounded",
          footer_keys = true,
          fix_buf = true,
          resize = true,
          stack = true,
          keys = {
            { "<Esc>", function(self) self:hide() end, mode = "t", desc = "Hide" },
            { "<C-h>", function() set_prev_win() end, mode = "t", desc = "⏮️" },
            { "<C-j>", function() set_prev_win() end, mode = "t", desc = "⏮️" },
            { "<C-k>", function() set_next_win() end, mode = "t", desc = "⏭️" },
            { "<C-l>", function() set_next_win() end, mode = "t", desc = "⏭️" },
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
}
