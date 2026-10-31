local ci = require("harness-decorators.context-inject")
local edit_jump = require("harness-decorators.edit-jump")
local term = require("harness-decorators.term")
local focus = require("harness-decorators.focus")
local zen = require("zen-mode.view")

describe("window selection contracts", function()
  local saved, tab, buffers, jobs, dir, opens, writes, placements

  local function file(name)
    local path = dir .. "/" .. name
    vim.fn.writefile({ "one", "two" }, path)
    return path
  end

  local function window(opts)
    opts = opts or {}
    local buf = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = buf
    vim.bo[buf].buftype = opts.buftype or ""
    if opts.name then
      vim.api.nvim_buf_set_name(buf, opts.name)
    end
    if opts.filetype then
      vim.bo[buf].filetype = opts.filetype
    end
    if opts.terminal then
      vim.api.nvim_buf_call(buf, function()
        jobs[#jobs + 1] = vim.fn.jobstart({ "sleep", "30" }, { term = true })
      end)
    end
    local win
    if opts.float then
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 20,
        height = 3,
        hide = opts.hidden or false,
      })
    else
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
    return win, buf
  end

  local function ordered(...)
    local selected = { ... }
    return vim.tbl_filter(function(win)
      return vim.tbl_contains(selected, win)
    end, vim.api.nvim_tabpage_list_wins(0))
  end

  local function jump(path)
    placements = {}
    edit_jump.on_edit({ data = { file_path = path, starting_line = 1 } })
  end

  before_each(function()
    saved = {
      tab = vim.api.nvim_get_current_tabpage(),
      eventignore = vim.o.eventignore,
      defer = vim.defer_fn,
      restore = focus.restore,
      suppress = focus.suppress_next_leave,
      back = focus.jump_to_saved,
      zen_open = zen.is_open,
      zen_win = zen.win,
      zen_parent = zen.parent,
      jump_win = edit_jump.jump_win,
      sources = edit_jump.edit_sources,
      bufnr = term.bufnr,
      open = term.open,
      chansend = vim.fn.chansend,
      config = vim.api.nvim_win_get_config,
      option = vim.api.nvim_get_option_value,
      set_buf = vim.api.nvim_win_set_buf,
    }
    vim.o.eventignore = "all"
    vim.cmd("tabnew")
    tab = vim.api.nvim_get_current_tabpage()
    buffers, jobs, opens, writes, placements = { vim.api.nvim_get_current_buf() }, {}, {}, {}, {}
    dir = vim.fn.tempname() .. "-windows"
    vim.fn.mkdir(dir, "p")
    focus.restore = function() end
    focus.suppress_next_leave = function() end
    focus.jump_to_saved = function()
      return false
    end
    zen.is_open = function()
      return false
    end
    edit_jump.jump_win = nil
    edit_jump.edit_sources = {}
    -- Run the selection step immediately; cursor/redraw callbacks are outside these contracts.
    vim.defer_fn = function(callback, delay)
      if delay == 250 then
        callback()
      end
    end
    term.bufnr = function()
      return nil
    end
    term.open = function(harness)
      opens[#opens + 1] = harness
    end
    vim.fn.chansend = function(channel, text)
      writes[#writes + 1] = { channel, text }
      return 1
    end
    vim.api.nvim_win_set_buf = function(win, buf)
      placements[#placements + 1] = win
      return saved.set_buf(win, buf)
    end
  end)

  after_each(function()
    vim.defer_fn = saved.defer
    focus.restore, focus.suppress_next_leave, focus.jump_to_saved = saved.restore, saved.suppress, saved.back
    zen.is_open, zen.win, zen.parent = saved.zen_open, saved.zen_win, saved.zen_parent
    edit_jump.jump_win, edit_jump.edit_sources = saved.jump_win, saved.sources
    term.bufnr, term.open = saved.bufnr, saved.open
    vim.fn.chansend = saved.chansend
    vim.api.nvim_win_get_config = saved.config
    vim.api.nvim_get_option_value = saved.option
    vim.api.nvim_win_set_buf = saved.set_buf
    for _, job in ipairs(jobs) do
      pcall(vim.fn.jobstop, job)
    end
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose!")
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

  it("Given two visible terminal windows, When finding a fallback, Then the first in tab order wins", function()
    local a = window({ terminal = true })
    local b = window({ terminal = true, float = true })
    assert.are.equal(ordered(a, b)[1], ci.find_terminal_win())
  end)

  it(
    "Given hidden terminals and special buffers, When finding a fallback, Then only the visible terminal qualifies",
    function()
      window({ terminal = true, float = true, hidden = true })
      window({ buftype = "nofile", filetype = "neo-tree" })
      window({ name = file("normal.txt") })
      local win = window({ terminal = true, float = true })
      assert.are.equal(win, ci.find_terminal_win())
    end
  )

  it("Given the current window is the only terminal, When finding a fallback, Then it is eligible", function()
    local win = window({ terminal = true })
    vim.api.nvim_set_current_win(win)
    assert.are.equal(win, ci.find_terminal_win())
  end)

  it("Given a config lookup error, When finding a terminal fallback, Then the terminal is still eligible", function()
    local win = window({ terminal = true })
    vim.api.nvim_win_get_config = function(w)
      if w == win then
        error("config unavailable")
      end
      return saved.config(w)
    end
    assert.are.equal(win, ci.find_terminal_win())
  end)

  it("Given terminals only in another tab, When finding a fallback, Then none is returned", function()
    window({ terminal = true })
    vim.cmd("tabnew")
    buffers[#buffers + 1] = vim.api.nvim_get_current_buf()
    assert.is_nil(ci.find_terminal_win())
    vim.cmd("tabclose!")
    vim.api.nvim_set_current_tabpage(tab)
  end)

  it(
    "Given an owned non-terminal buffer, When sending context, Then exact buffer identity wins without a buftype gate",
    function()
      window({ terminal = true })
      local win, buf = window({ float = true })
      vim.b[buf].terminal_job_id = 1234
      term.bufnr = function()
        return buf
      end
      assert.are.equal(win, ci.type_into_terminal("context", nil, "pig"))
      assert.are.same({ { 1234, "context " } }, writes)
      assert.are.same({}, opens)
    end
  )

  it(
    "Given an owned hidden float and another terminal, When sending context, Then the owned float is re-shown rather than using the other terminal",
    function()
      window({ terminal = true })
      local win, buf = window({ terminal = true, float = true, hidden = true })
      term.bufnr = function()
        return buf
      end
      term.open = function(harness)
        opens[#opens + 1] = harness
        vim.api.nvim_win_set_config(win, { hide = false })
      end
      assert.are.equal(win, ci.type_into_terminal("context", nil, "pig"))
      assert.are.same({ "pig" }, opens)
      assert.are.equal(vim.bo[buf].channel, writes[1][1])
    end
  )

  it("Given the owned buffer is displayed twice, When sending context, Then the first visible view wins", function()
    local a, buf = window({ terminal = true })
    local b = window({ float = true })
    vim.api.nvim_win_set_buf(b, buf)
    term.bufnr = function()
      return buf
    end
    assert.are.equal(ordered(a, b)[1], ci.type_into_terminal("context", nil, "pig"))
  end)

  it("Given no owned buffer, When sending context, Then the visible terminal fallback is used", function()
    local win = window({ terminal = true, float = true })
    assert.are.equal(win, ci.type_into_terminal("context", nil, "pig"))
    assert.are.same({}, opens)
  end)

  it(
    "Given two named file windows, When an unseen file is edited, Then the last in tab order wins even when its path is absent",
    function()
      local a = window({ name = dir .. "/unsaved-a.txt" })
      local b = window({ name = dir .. "/unsaved-b.txt" })
      jump(file("target.txt"))
      assert.are.equal(ordered(a, b)[2], edit_jump.jump_win)
    end
  )

  it("Given the current window is the only named normal buffer, When a file is edited, Then it is eligible", function()
    local win = window({ name = dir .. "/current-unsaved.txt" })
    jump(file("target.txt"))
    assert.are.equal(win, edit_jump.jump_win)
  end)

  it(
    "Given only floats, unnamed and special buffers, When an unseen file is edited, Then no adjacent window is chosen",
    function()
      window({ name = file("float.txt"), float = true })
      window({ name = file("tree.txt"), buftype = "nofile", filetype = "neo-tree" })
      window({ name = file("help.txt"), buftype = "help" })
      window({ terminal = true })
      jump(file("target.txt"))
      assert.is_nil(edit_jump.jump_win)
    end
  )

  it(
    "Given a named normal neo-tree buffer, When an unseen file is edited, Then filetype alone does not disqualify it",
    function()
      local win = window({ name = dir .. "/normal-tree", filetype = "neo-tree" })
      jump(file("target.txt"))
      assert.are.equal(win, edit_jump.jump_win)
    end
  )

  it(
    "Given a buftype lookup error, When an unseen file is edited, Then its named normal window is still eligible",
    function()
      local win, buf = window({ name = dir .. "/unreadable-option" })
      vim.api.nvim_get_option_value = function(name, opts)
        if name == "buftype" and opts.buf == buf then
          error("option unavailable")
        end
        return saved.option(name, opts)
      end
      jump(file("target.txt"))
      assert.are.equal(win, edit_jump.jump_win)
    end
  )

  it(
    "Given the target file already has a normal window, When it is edited, Then that view beats the adjacent window",
    function()
      local target = file("target.txt")
      local win = window({ name = target })
      local other, other_buf = window({ name = file("other.txt") })
      edit_jump.jump_win = other
      jump(target)
      assert.are.same({ win }, placements)
      assert.are.equal(other_buf, vim.api.nvim_win_get_buf(other))
      assert.are.equal(target, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    end
  )

  it("Given zen is open, When a file is edited, Then zen and its parent beat the normal-window search", function()
    local parent = window({ name = file("parent.txt") })
    local zwin = window({ name = file("zen.txt"), float = true })
    zen.win, zen.parent = zwin, parent
    zen.is_open = function()
      return true
    end
    local target = file("target.txt")
    jump(target)
    assert.are.equal(target, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(zwin)))
    assert.are.equal(vim.api.nvim_win_get_buf(zwin), vim.api.nvim_win_get_buf(parent))
    assert.is_nil(edit_jump.jump_win)
  end)

  it("Given a saved jump window, When an unseen file is edited, Then it beats a new adjacent candidate", function()
    local saved_win = window({ name = file("saved.txt") })
    window({ name = file("other.txt") })
    edit_jump.jump_win = saved_win
    local target = file("target.txt")
    jump(target)
    assert.are.equal(target, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(saved_win)))
  end)

  it(
    "Given no saved focus target, When term returns to work, Then it picks the last existing-path window other than the current one",
    function()
      local a = window({ name = file("a.txt") })
      local b = window({ name = file("b.txt") })
      window({ name = dir .. "/absent.txt" })
      local current = window({ name = file("current.txt") })
      vim.api.nvim_set_current_win(current)
      term.go_back_key({})
      assert.are.equal(ordered(a, b)[2], vim.api.nvim_get_current_win())
    end
  )

  it(
    "Given a saved focus target, When term returns to work, Then it uses that target before its reverse scan",
    function()
      local win = window({ name = file("saved.txt") })
      window({ name = file("other.txt") })
      focus.jump_to_saved = function()
        vim.api.nvim_set_current_win(win)
        return true
      end
      term.go_back_key({})
      assert.are.equal(win, vim.api.nvim_get_current_win())
    end
  )

  it("Given a file-backed special float, When term falls back, Then the float is eligible", function()
    local win = window({ name = file("tree-float.txt"), buftype = "nofile", filetype = "neo-tree", float = true })
    term.go_back_key({})
    assert.are.equal(win, vim.api.nvim_get_current_win())
  end)
end)

describe("windows.find", function()
  local original_list, original_config, wins, configs, visited

  local function finder()
    local ok, module = pcall(require, "harness-decorators.windows")
    assert.is_true(ok, "the shared finder must load: " .. tostring(module))
    return module.find
  end

  before_each(function()
    original_list, original_config = vim.api.nvim_tabpage_list_wins, vim.api.nvim_win_get_config
    wins, configs, visited = { 11, 12, 13 }, {}, {}
    vim.api.nvim_tabpage_list_wins = function(tabpage)
      assert.are.equal(0, tabpage, "search only the current tab")
      return wins
    end
    vim.api.nvim_win_get_config = function(win)
      if configs[win] == "error" then
        error("config unavailable")
      end
      return configs[win] or {}
    end
  end)

  after_each(function()
    vim.api.nvim_tabpage_list_wins, vim.api.nvim_win_get_config = original_list, original_config
  end)

  local function matches(win)
    visited[#visited + 1] = win
    return win == 12
  end

  it("Given tab windows in order, When finding a match, Then traversal stops at the first accepted window", function()
    assert.are.equal(12, finder()(matches))
    assert.are.same({ 11, 12 }, visited)
  end)

  it(
    "Given reverse order, When finding a match, Then traversal starts at the last window without changing the list",
    function()
      assert.are.equal(12, finder()(matches, { reverse = true }))
      assert.are.same({ 13, 12 }, visited)
      assert.are.same({ 11, 12, 13 }, wins)
    end
  )

  it("Given no matching window, When finding a match, Then nil is returned", function()
    assert.is_nil(finder()(function()
      return false
    end))
  end)

  it("Given an empty tab list, When finding a match in either order, Then the matcher is not called", function()
    wins = {}
    local function unexpected()
      error("empty lists must not call the matcher")
    end
    assert.is_nil(finder()(unexpected))
    assert.is_nil(finder()(unexpected, { reverse = true }))
  end)

  it("Given visible-only selection, When the first window is hidden, Then it is skipped before matching", function()
    configs[11] = { hide = true }
    assert.are.equal(12, finder()(matches, { visible = true }))
    assert.are.same({ 12 }, visited)
  end)

  it("Given no visibility filter, When a hidden window matches, Then it remains eligible", function()
    configs[11] = { hide = true }
    assert.are.equal(
      11,
      finder()(function()
        return true
      end)
    )
  end)

  it(
    "Given a config lookup failure, When visible-only selection runs, Then the matcher still decides eligibility",
    function()
      configs[11] = "error"
      assert.are.equal(
        11,
        finder()(function()
          return true
        end, { visible = true })
      )
    end
  )

  it("Given a failing matcher, When searching, Then its error reaches the caller", function()
    local find = finder()
    local ok, err = pcall(find, function()
      error("matcher failed")
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("matcher failed", 1, true))
  end)
end)
