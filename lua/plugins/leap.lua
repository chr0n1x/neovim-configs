return {
  'ggandor/leap.nvim',
  lazy = false,
  config = function()
    local leap = require('leap')

    -- disable jumping to first match
    leap.opts.safe_labels = {}
    vim.api.nvim_set_hl(0, 'LeapBackdrop', { link = 'Comment', fg = '#777777' })

    -- use leap in all visible windows
    vim.keymap.set('n', 's', function ()
      local focusable_windows = vim.tbl_filter(
        function (win) return vim.api.nvim_win_get_config(win).focusable end,
        vim.api.nvim_tabpage_list_wins(0)
      )
      leap.leap { target_windows = focusable_windows }
    end)

    if not IN_PERF_MODE then
      -- https://github.com/ggandor/leap.nvim/issues/256
      -- TODO: does not work with multiple panes. for now
      vim.api.nvim_create_autocmd("User", {
        pattern = "LeapEnter",
        callback = function()
          vim.api.nvim_create_autocmd("CursorMoved", {
            once = true,
            callback = function() require('neoscroll').zz({ half_win_duration = 250 }) end
          })
        end
      })
    end
  end
}
