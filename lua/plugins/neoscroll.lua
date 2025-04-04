return {
  "karb94/neoscroll.nvim",
  init = function()

    neoscroll = require('neoscroll')
    neoscroll.setup({
      hide_cursor = true,            -- Hide cursor while scrolling
      stop_eof = true,               -- Stop at <EOF> when scrolling downwards
      respect_scrolloff = false,     -- Stop scrolling when the cursor reaches the scrolloff margin of the file
      cursor_scrolls_alone = false,  -- The cursor will keep on scrolling even if the window cannot scroll further
      easing_function = 'quadratic', -- Default easing function
      pre_hook = nil,                -- Function to run before the scrolling animation starts
      post_hook = nil,               -- Function to run after the scrolling animation ends
      performance_mode = false,      -- Disable "Performance Mode" on all buffers.
    })

    local keymap = {
      ["<C-b>"]     = function() neoscroll.ctrl_b({ duration = 125 }) end;
      ["<C-f>"]     = function() neoscroll.ctrl_f({ duration = 125 }) end;
      ["<leader>j"] = function() neoscroll.scroll(0.25, { move_cursor=true; duration = 250 }) end;
      ["<leader>k"] = function() neoscroll.scroll(-0.25, { move_cursor=true; duration = 250 }) end;
      ["zt"]        = function() neoscroll.zt({ half_win_duration = 250 }) end;
      ["zz"]        = function() neoscroll.zz({ half_win_duration = 250 }) end;
      ["zb"]        = function() neoscroll.zb({ half_win_duration = 250 }) end;

    }
    local modes = { 'n', 'v', 'x' }
    for key, func in pairs(keymap) do
      vim.keymap.set(modes, key, func)
    end
  end
}

