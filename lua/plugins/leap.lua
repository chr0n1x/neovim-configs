leap = require('leap')

leap.create_default_mappings()

-- disable jumping to first match
leap.opts.safe_labels = {}

-- Or just set to grey directly, e.g. { fg = '#777777' },
-- if Comment is saturated.
vim.api.nvim_set_hl(0, 'LeapBackdrop', { link = 'Comment' })

-- use leap in all visible windows
vim.keymap.set('n', 's', function ()
  local focusable_windows = vim.tbl_filter(
    function (win) return vim.api.nvim_win_get_config(win).focusable end,
    vim.api.nvim_tabpage_list_wins(0)
  )
  leap.leap { target_windows = focusable_windows }
end)
