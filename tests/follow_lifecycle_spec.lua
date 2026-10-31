-- Session following (the JSONL watcher) is tied to each harness's own process: when it exits the
-- watcher stops for it, activating its dead float does not start it again, and only a fresh start
-- of that harness does. Another harness's following is not affected by the exit.
describe("session following across harness exits", function()
  local term = require("harness-decorators.term")
  local active = require("harness-decorators.active")
  local watcher = require("harness-decorators.watcher")
  local snacks, orig_open, orig_harness
  local orig_stop, orig_start, orig_reset
  local starts, resets, stops

  local function fake(with_job)
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
    if with_job then
      vim.api.nvim_buf_call(inst.buf, function()
        vim.fn.jobstart({ "sleep", "60" }, { term = true })
      end)
    end
    inst:show()
    return inst
  end

  local with_job = false

  ---Open the harness with a running process and end that process; returns the instance.
  local function open_and_exit(harness)
    with_job = true
    local inst = term.open(harness)
    with_job = false
    local before = stops
    vim.fn.jobstop(vim.bo[inst.buf].channel)
    assert.is_true(
      vim.wait(2000, function()
        return stops > before
      end, 10),
      "precondition: the watcher stops when the active harness exits"
    )
    return inst
  end

  setup(function()
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      return fake(with_job)
    end
  end)

  teardown(function()
    snacks.open = orig_open
  end)

  before_each(function()
    orig_harness = active.get()
    orig_stop, orig_start, orig_reset = watcher.stop, watcher.start, watcher.reset_pin_state
    starts, resets, stops = {}, 0, 0
    watcher.stop = function()
      stops = stops + 1
    end
    watcher.start = function()
      table.insert(starts, active.get())
    end
    watcher.reset_pin_state = function()
      resets = resets + 1
    end
  end)

  after_each(function()
    watcher.stop, watcher.start, watcher.reset_pin_state = orig_stop, orig_start, orig_reset
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    term._reset()
    active.set(orig_harness)
  end)

  it(
    "Given claude's process exited and copilot was activated, When claude's dead float gets focus, Then watcher.start is not called for claude",
    function()
      active.set("claude")
      local claude = open_and_exit("claude")
      require("harness-decorators.switch").activate("copilot")
      assert.are.equal("copilot", active.get(), "precondition: copilot is active")
      starts = {}

      vim.api.nvim_set_current_win(claude.win)
      assert.is_true(
        vim.wait(1000, function()
          return active.get() == "claude"
        end, 10),
        "precondition: focusing the float activates claude"
      )

      assert.are.same({}, starts, "following must not restart for an exited harness")
    end
  )

  it(
    "Given claude exited and copilot is followed with a pin, When copilot opens a new float, Then the pin is kept",
    function()
      active.set("claude")
      open_and_exit("claude")
      active.set("copilot")
      starts, resets = {}, 0

      term.open("copilot")

      assert.are.equal(0, resets, "copilot's pin must not be dropped by claude's exit")
      assert.are.same({}, starts, "copilot's following was never stopped, so it is not restarted")
    end
  )

  it("Given the active harness exits, When it is started fresh, Then following restarts for the new session", function()
    active.set("claude")
    open_and_exit("claude")
    starts, resets = {}, 0

    require("harness-decorators.state").table.claude = nil
    term.open("claude")

    assert.are.same({ "claude" }, starts, "a fresh start must restart following")
    assert.is_true(resets > 0, "the old session's pin must be dropped")
  end)

  it("Given claude exited with following off, When term._reset runs, Then following is no longer paused", function()
    active.set("claude")
    open_and_exit("claude")
    assert.is_true(term.follow_paused("claude"), "precondition: claude's following is paused")

    term._reset()

    assert.is_false(term.follow_paused("claude"), "_reset must clear the follow pause")
  end)

  it(
    "Given claude exited and is active with following off, When copilot is activated, Then watcher.start is called once for copilot",
    function()
      active.set("claude")
      open_and_exit("claude")
      starts = {}

      require("harness-decorators.switch").activate("copilot")

      assert.are.same({ "copilot" }, starts, "a live harness must be followed after leaving an exited one")
    end
  )

  it(
    "Given claude was opened with <leader>cc and its process exited non-zero before any <leader>c, When <leader>c runs, Then watcher.start is not called for claude",
    function()
      active.set("claude")
      open_and_exit("claude")
      starts = {}
      -- A fresh module, so its once-per-session follow setup has not run yet.
      local saved = package.loaded["harness-decorators"]
      package.loaded["harness-decorators"] = nil
      local ok, err = pcall(function()
        require("harness-decorators").setup_auto_follow()
      end)
      package.loaded["harness-decorators"] = saved
      assert.is_true(ok, tostring(err))

      assert.are.same({}, starts, "the first <leader>c must not follow an exited harness")
    end
  )

  it(
    "Given a minimized float whose harness switch rejects, When its bar restore is clicked, Then that float comes back and the active harness is not re-shown",
    function()
      local utils = require("harness-decorators.utils")
      local orig_list = utils.list_harnesses
      active.set("claude")
      local claude = term.open("claude")
      local copilot = term.open("copilot")
      claude:hide()
      active.set("claude")
      utils.list_harnesses = function()
        return { "claude" }
      end
      local ok, err = pcall(function()
        assert.is_true(term.minimize("copilot"), "precondition: copilot minimizes")
        assert.is_true(
          vim.wait(3000, function()
            return copilot._pill_win ~= nil and vim.api.nvim_win_is_valid(copilot._pill_win)
          end, 10),
          "precondition: copilot's bar is shown"
        )
        local pos = vim.api.nvim_win_get_position(copilot._pill_win)
        term.mouse.press({ screenrow = pos[1] + 2, screencol = pos[2] + 2 + copilot._bar_close_col - 3 })
        term.mouse.release()
        assert.is_true(
          vim.wait(3000, function()
            return copilot.win ~= nil and vim.api.nvim_win_is_valid(copilot.win)
          end, 10),
          "the clicked float must come back"
        )
        assert.is_nil(claude.win, "the active harness must not be shown instead")
      end)
      utils.list_harnesses = orig_list
      assert.is_true(ok, tostring(err))
    end
  )
end)
