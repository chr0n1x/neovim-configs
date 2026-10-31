-- Where focus goes when the focused harness float leaves and there is no saved window to return
-- to: float-util's find_base_window picks the last window in the tab that is not the current one
-- and shows a file on disk.
describe("find_base_window", function()
  local focus = require("harness-decorators.focus")
  local float_util = require("harness-decorators.float-util")
  local snacks, orig_open
  local files = {}

  local function fake()
    local inst = {
      buf = vim.api.nvim_create_buf(false, true),
      opts = { border = "rounded", row = 2, col = 10, width = 40, height = 10 },
    }
    function inst:buf_valid()
      return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
    end
    function inst:show()
      self.win = vim.api.nvim_open_win(self.buf, false, {
        relative = "editor",
        row = self.opts.row,
        col = self.opts.col,
        width = self.opts.width,
        height = self.opts.height,
        border = "rounded",
      })
    end
    function inst:hide()
      if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
      end
      self.win = nil
    end
    function inst:focus() end
    function inst.close() end
    inst:show()
    return inst
  end

  local function single_window()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  local function file_buf(name)
    local path = vim.fn.tempname() .. name
    vim.fn.writefile({ name }, path)
    table.insert(files, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
  end

  setup(function()
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = fake
  end)

  teardown(function()
    snacks.open = orig_open
  end)

  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    require("harness-decorators.term")._reset()
    focus.reset()
    single_window()
    for _, path in ipairs(files) do
      vim.fn.delete(path)
    end
    files = {}
  end)

  it(
    "Given the focused float with no saved target and two file windows, When it is minimized, Then focus lands on the last existing-path window that is not a harness float",
    function()
      local term = require("harness-decorators.term")
      single_window()
      vim.api.nvim_set_current_buf(file_buf("-first.txt"))
      vim.cmd("vsplit")
      vim.api.nvim_set_current_buf(file_buf("-second.txt"))
      local wins = vim.api.nvim_tabpage_list_wins(0)
      local last_file_win = wins[#wins]

      local inst = term.open("claude")
      vim.api.nvim_set_current_win(inst.win)
      focus.reset()
      assert.is_nil(focus.last_win, "precondition: no saved window")

      assert.is_true(term.minimize("claude"))

      local cur = vim.api.nvim_get_current_win()
      assert.are.equal(last_file_win, cur)
      assert.are.equal("", vim.api.nvim_win_get_config(cur).relative, "focus must not land on a float")
    end
  )

  it("Given a hidden float showing an existing file, When find_base_window runs, Then it is still eligible", function()
    single_window()
    local start = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    local hidden = vim.api.nvim_open_win(file_buf("-hidden.txt"), false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 20,
      height = 3,
      hide = true,
    })
    assert.is_true(vim.api.nvim_win_get_config(hidden).hide, "precondition: the float is hidden")

    local orig_set = vim.api.nvim_set_current_win
    local picked
    vim.api.nvim_set_current_win = function(win)
      picked = win
    end
    local ok, err = pcall(float_util.find_base_window)
    vim.api.nvim_set_current_win = orig_set
    assert.is_true(ok, err)

    assert.are.equal(hidden, picked)
    assert.are.equal(start, vim.api.nvim_get_current_win())
  end)
end)

describe("find_base_window: no eligible window", function()
  local float_util = require("harness-decorators.float-util")
  local saved, tabs, buffers, dir

  local function buffer(name, on_disk)
    local buf = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = buf
    if name then
      local path = dir .. "/" .. name
      vim.api.nvim_buf_set_name(buf, path)
      if on_disk then
        vim.fn.writefile({ "work" }, path)
      end
    end
    return buf
  end

  local function assert_no_focus()
    local start = vim.api.nvim_get_current_win()
    local calls = 0
    vim.api.nvim_set_current_win = function(_)
      calls = calls + 1
    end

    assert.is_nil(float_util.find_base_window())
    assert.are.equal(0, calls, "no eligible candidate must mean zero focus calls, even with nil")
    assert.are.equal(start, vim.api.nvim_get_current_win())
  end

  before_each(function()
    saved = {
      tab = vim.api.nvim_get_current_tabpage(),
      eventignore = vim.o.eventignore,
      set_win = vim.api.nvim_set_current_win,
    }
    tabs, buffers = {}, {}
    vim.o.eventignore = "all"
    vim.cmd("tabnew")
    tabs[1] = vim.api.nvim_get_current_tabpage()
    buffers[1] = vim.api.nvim_get_current_buf()
    dir = vim.fn.tempname() .. "-no-base-window"
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.api.nvim_set_current_win = saved.set_win
    for ix = #tabs, 1, -1 do
      if vim.api.nvim_tabpage_is_valid(tabs[ix]) then
        vim.api.nvim_set_current_tabpage(tabs[ix])
        vim.cmd("tabclose!")
      end
    end
    vim.api.nvim_set_current_tabpage(saved.tab)
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
    vim.o.eventignore = saved.eventignore
  end)

  it(
    "Given the current window is the only existing-path candidate, When find_base_window runs, Then it makes zero focus calls",
    function()
      vim.api.nvim_set_current_buf(buffer("current.txt", true))
      assert.is_not_nil(vim.uv.fs_stat(dir .. "/current.txt"), "precondition: the current path exists")
      assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))

      assert_no_focus()
    end
  )

  it(
    "Given only unnamed or missing-path buffers in this tab and an eligible window in another tab, When find_base_window runs, Then it makes zero focus calls",
    function()
      local current_tab = vim.api.nvim_get_current_tabpage()
      assert.are.equal("", vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
      vim.api.nvim_open_win(buffer("missing.txt"), false, { split = "right" })
      assert.is_nil(vim.uv.fs_stat(dir .. "/missing.txt"), "precondition: the other local path is absent")
      assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))

      vim.cmd("tabnew")
      tabs[2] = vim.api.nvim_get_current_tabpage()
      buffers[#buffers + 1] = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_current_buf(buffer("other-tab.txt", true))
      assert.is_not_nil(vim.uv.fs_stat(dir .. "/other-tab.txt"), "precondition: the other tab's path exists")
      vim.api.nvim_set_current_tabpage(current_tab)

      assert_no_focus()
    end
  )
end)
