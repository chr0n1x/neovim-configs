local nmap = vim.api.nvim_set_keymap

vim.g.mapleader = " "

-- these are put here because most of these I consider core functionality
-- that's ingrained in my muscle memory. There may be more key mappings in the
-- plugins/ dir tied to specific plugins. in nvim itself, hit <Space> and do
-- nothing to let the which-key plugin list possible keymappings

-- buffer navigation
nmap("n", "<leader>s", ":/<C-r><C-w>/<CR>", { noremap = true, desc = "Search word underneath cursor." })

-- tab navigation
nmap("n", "<leader>n", ":tabnext<CR>", { noremap = true, desc = "Tab; next" })
nmap("n", "<leader>b", ":tabprevious<CR>", { noremap = true, desc = "Tab; prev" })
nmap("n", "<leader>o", ":tabe<space>", { noremap = true, desc = "Tab; open" })

-- editor visuals & "ergonomics"
nmap("n", "<leader>M", ":set mouse!<CR>", { noremap = true, desc = "Toggle mouse mode." })
nmap("n", "<leader>z", ":set scrolloff=3<CR>", { noremap = true, desc = "Do not center cursor on screen." })
nmap("n", "<leader>Z", ":set scrolloff=999<CR>", { noremap = true, desc = "Center cursor on screen." })

-- misc
nmap("n", "<leader>w", ":w<CR>", { noremap = true, desc = "Save buff." })
-- windows.nvim's autowidth runs only from here (its automatic resizing is disabled in plugins/uix.lua).
-- It has no one-shot command, so this drives its layout calculation and animation directly.
local function autowidth_once()
  local ok_api, api = pcall(require, "windows.lib.api")
  local ok_calc, calc_layout = pcall(require, "windows.calculate-layout")
  if not (ok_api and ok_calc) then
    return
  end
  local win = api.Window(0)
  if win:is_floating() or win:is_ignored() then
    return
  end
  local winsdata = calc_layout.autowidth(win)
  if vim.tbl_isempty(winsdata) then
    return
  end
  local animation = require("windows.lib.resize-windows-animated")._instance
  if animation then
    animation:load(winsdata)
    animation:run()
  else
    require("windows.lib.resize-windows").resize_windows(winsdata)
  end
end
nmap("n", "<leader><space>", "", {
  noremap = true,
  desc = "Close any highlights and resize windows for the current one.",
  callback = function()
    vim.cmd("noh | e")
    autowidth_once()
  end,
})
nmap("n", "<leader>q", ":q<CR>", { noremap = true, desc = "Save & close buffer (:wq)." })
nmap("n", "<leader>qq", ":qa!<CR>", { noremap = true, desc = "Force close all. (:qa!)" })
nmap("n", "<leader>md", ":delm! | delm A-Z0-9<CR>", { noremap = true, desc = "Marks: Delete all." })
nmap("n", "er", ":", { noremap = true, desc = "Quick-enter into command mode." })

-- utility scripts
-- pretty-format JSON in the current buffer/file
nmap(
  "n",
  "<leader>J",
  ":%!python3 -m json.tool --sort-keys<CR>",
  { noremap = true, desc = "Use python to pretty-format JSON" }
)
