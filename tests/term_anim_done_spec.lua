-- The completion contract of terminal-animations.animate_win: on_done runs exactly once when the
-- current animation lands, never for one a newer animation cut off, and the no-animation.nvim path
-- still runs it, so a minimized harness restored without the plugin really shows its float.
describe("window animation completion", function()
  local anims = require("harness-decorators.terminal-animations")
  local state = require("harness-decorators.state")
  local saved = {}

  ---A controllable animation.nvim stand-in: frames run only when step() is called, and finish()
  -- stops further frames the way the real timer does.
  local started
  local function install_stub()
    started = {}
    saved.animation, saved.easing = package.loaded["animation"], package.loaded["animation.easing"]
    package.loaded["animation.easing"] = {
      in_out_sine = function(x)
        return x
      end,
    }
    package.loaded["animation"] = function(_, _, _, frame)
      local a = { frame = frame, stopped = false }
      function a:run() end
      function a:finish()
        self.stopped = true
      end
      function a:step(f)
        if not self.stopped then
          return self.frame(f)
        end
      end
      table.insert(started, a)
      return a
    end
  end

  local function restore_animation()
    package.loaded["animation"], package.loaded["animation.easing"] = saved.animation, saved.easing
    package.preload["animation"] = nil
  end

  local function float()
    local buf = vim.api.nvim_create_buf(false, true)
    return vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 5 })
  end

  after_each(function()
    restore_animation()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    require("harness-decorators.term")._reset()
  end)

  it(
    "Given two moves on the same handle, When the old and then the current one complete, Then only the current on_done runs, exactly once",
    function()
      install_stub()
      local win = float()
      local handle = {}
      local calls = { old = 0, new = 0 }
      anims.animate_win(handle, "_anim", win, { row = 2, col = 2, width = 30, height = 6 }, nil, function()
        calls.old = calls.old + 1
      end)
      local to = { row = 4, col = 6, width = 25, height = 7 }
      anims.animate_win(handle, "_anim", win, to, nil, function()
        calls.new = calls.new + 1
      end)
      assert.are.equal(2, #started)
      assert.are.equal(started[2], handle._anim)

      started[1]:step(1)
      started[2]:step(0.5)
      started[2]:step(1)
      started[2]:step(1)

      assert.are.same({ old = 0, new = 1 }, calls)
      local cfg = vim.api.nvim_win_get_config(win)
      assert.are.same(
        to,
        { row = math.floor(cfg.row), col = math.floor(cfg.col), width = cfg.width, height = cfg.height }
      )
    end
  )

  it("Given no animation.nvim, When a move runs, Then it lands and on_done runs once, synchronously", function()
    package.loaded["animation"] = nil
    package.preload["animation"] = function()
      error("animation.nvim not installed")
    end
    local win = float()
    local done = 0
    anims.animate_win({}, "_anim", win, { row = 3, col = 4, width = 10, height = 2 }, nil, function()
      done = done + 1
    end)
    assert.are.equal(1, done)
    assert.are.equal(10, vim.api.nvim_win_get_width(win))
  end)

  it("Given a minimized harness and no animation.nvim, When it is shown, Then its real float is visible", function()
    local snacks = require("snacks.terminal")
    local orig_open = snacks.open
    snacks.open = function()
      local inst = {
        buf = vim.api.nvim_create_buf(false, true),
        opts = { border = "rounded", row = 2, col = 10, width = 40, height = 10 },
      }
      function inst:buf_valid()
        return vim.api.nvim_buf_is_valid(self.buf)
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
    local ok, err = pcall(function()
      package.loaded["animation"] = nil
      package.preload["animation"] = function()
        error("animation.nvim not installed")
      end
      local term = require("harness-decorators.term")
      local inst = term.open("claude")
      assert.is_true(term.minimize("claude"))
      local bar = inst._pill_win
      assert.is_nil(inst.win, "precondition: the float is hidden")

      term.show("claude")

      assert.is_true(inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win), "the harness float must be open")
      assert.are.equal(inst.buf, vim.api.nvim_win_get_buf(inst.win))
      assert.is_false(vim.api.nvim_win_is_valid(bar), "the bar must be gone")
      assert.are.equal(inst, state.table["claude"].inst)
    end)
    snacks.open = orig_open
    assert(ok, err)
  end)
end)
