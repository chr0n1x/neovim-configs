-- Spec for key-bindings.lua. windows.nvim's automatic resizing is disabled (plugins/uix.lua), and
-- <leader><space> runs its autowidth once, on demand, after clearing search highlights.

describe("key-bindings: <leader><space>", function()
  local path

  local function widths()
    local out = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative == "" then
        out[w] = vim.api.nvim_win_get_width(w)
      end
    end
    return out
  end

  local function only_window()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  before_each(function()
    only_window()
    path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "one", "two" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.cmd("vsplit | vsplit | wincmd =")
  end)

  after_each(function()
    only_window()
    -- Wipe the buffer before deleting its file: a loaded buffer whose file vanished raises E211 on the
    -- next file check, which blocks the headless run on a prompt.
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 then
      vim.cmd("enew")
      vim.cmd("bwipeout! " .. buf)
    end
    vim.fn.delete(path)
  end)

  it(
    "Given three side-by-side windows, When focus moves between them, Then windows.nvim does not resize them",
    function()
      local before = widths()
      vim.cmd("wincmd l")
      vim.wait(500)
      assert.are.same(before, widths(), "moving focus must not trigger an automatic resize")
    end
  )

  it(
    "Given three side-by-side windows, When <leader><space> is pressed, Then highlights clear and the current window widens",
    function()
      vim.fn.setreg("/", "one")
      vim.o.hlsearch = true
      vim.cmd("let v:hlsearch = 1")
      local win = vim.api.nvim_get_current_win()
      local before = vim.api.nvim_win_get_width(win)
      local map = vim.fn.maparg("<leader><space>", "n", false, true)
      assert.is_not_nil(map.callback, "<leader><space> must be a Lua callback mapping")
      map.callback()
      local widened = vim.wait(1000, function()
        return vim.api.nvim_win_get_width(win) > before
      end, 10)
      -- Let the resize animation finish: closing its windows mid-animation breaks windows.nvim's timer.
      local anim = package.loaded["windows.lib.resize-windows-animated"]
      vim.wait(1000, function()
        return not (anim and anim._instance and anim._instance:is_running())
      end, 10)
      assert.is_true(widened, "the current window should widen (was " .. before .. ")")
      assert.are.equal(0, vim.v.hlsearch, "search highlights must be cleared")
    end
  )
end)
