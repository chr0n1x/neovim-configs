-- A <C-t> cycle press (term.tile with every float already in its grid spot) moves focus to the next
-- float by name. Only the float leaving the focus spot and the float taking it move, and each should
-- animate once, to its final rect.
describe("term.tile cycle press", function()
  local term = require("harness-decorators.term")
  local state = require("harness-decorators.state")
  local active = require("harness-decorators.active")
  local sw = require("harness-decorators.switch")
  local watcher = require("harness-decorators.watcher")
  local anim = require("harness-decorators.terminal-animations")
  local snacks = require("snacks.terminal")
  local saved

  local function make_float_fake(buf)
    local inst = { buf = buf, opts = { border = "rounded", row = 2, col = 10, width = 40, height = 10 } }
    function inst:buf_valid()
      return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
    end
    function inst:show()
      self.win = vim.api.nvim_open_win(self.buf, true, {
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
    function inst:focus()
      vim.api.nvim_set_current_win(self.win)
    end
    function inst.close() end
    return inst
  end

  local function rect_of(win)
    local c = vim.api.nvim_win_get_config(win)
    return { row = math.floor(c.row), col = math.floor(c.col), width = c.width, height = c.height }
  end

  before_each(function()
    saved = {
      open = snacks.open,
      animate = anim.animate_resize,
      start = watcher.start,
      stop = watcher.stop,
      active = active.get(),
      env = vim.env.NVIM_LLM_HARNESS,
      columns = vim.o.columns,
    }
    vim.o.columns = 300
    snacks.open = function()
      local inst = make_float_fake(vim.api.nvim_create_buf(false, true))
      inst:show()
      return inst
    end
    watcher.start = function() end
    watcher.stop = function() end
    term._reset()
    sw.init("claude")
  end)

  after_each(function()
    anim.animate_resize = saved.animate
    snacks.open, watcher.start, watcher.stop = saved.open, saved.start, saved.stop
    for _, e in pairs(state.table) do
      local i = e.inst
      if i and i.win and vim.api.nvim_win_is_valid(i.win) then
        if i._resize_anim then
          i._resize_anim:finish()
        end
        vim.api.nvim_win_close(i.win, true)
      end
    end
    term._reset()
    sw.init(saved.active)
    vim.env.NVIM_LLM_HARNESS = saved.env
    vim.o.columns = saved.columns
  end)

  it(
    "Given three floats tiled in their grid spots with claude focused, When <C-t> is pressed once, Then the two moving floats each animate once and no animation is cut off",
    function()
      local copilot = term.open("copilot")
      local maki = term.open("maki")
      local claude = term.open("claude")
      vim.api.nvim_set_current_win(claude.win)
      term.tile()
      vim.wait(1000)
      local before = { claude = rect_of(claude.win), copilot = rect_of(copilot.win), maki = rect_of(maki.win) }

      local calls, done = {}, 0
      anim.animate_resize = function(i, rect, on_done)
        local started = saved.animate(i, rect, function()
          done = done + 1
          if on_done then
            on_done()
          end
        end)
        if started then
          table.insert(calls, state.harness_of(i))
        end
        return started
      end
      term.tile()
      vim.wait(1000)

      assert.are.equal(copilot.win, vim.api.nvim_get_current_win(), "focus cycles to copilot")
      assert.are.equal("copilot", active.get(), "copilot is the active harness")
      assert.are.same(before.claude, rect_of(copilot.win), "copilot takes the focus spot")
      assert.are.same(before.copilot, rect_of(claude.win), "claude takes copilot's grid cell")
      assert.are.same(before.maki, rect_of(maki.win), "maki stays in its cell")
      table.sort(calls)
      assert.are.same({ "claude", "copilot" }, calls, "one animation per moving float")
      assert.are.equal(#calls, done, "every animation lands (none cut off by a later retile)")
    end
  )
end)
