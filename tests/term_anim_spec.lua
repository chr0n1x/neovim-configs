-- Pins where the two window animations land: a float resize (terminal-animations.animate_resize,
-- behind term's resize_to) and a minimized bar (term.minimize). Each must end on its target rect and
-- run on_done, with animation.nvim present and without it.
describe("window animation lands on the target rect", function()
  local state = require("harness-decorators.state")
  local snacks, orig_open, saved_animation

  local function rect_of(win)
    local cfg = vim.api.nvim_win_get_config(win)
    return { row = math.floor(cfg.row), col = math.floor(cfg.col), width = cfg.width, height = cfg.height }
  end

  local function open_float()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 2,
      col = 10,
      width = 40,
      height = 10,
      border = "rounded",
    })
    return { buf = buf, win = win, opts = { border = "rounded" } }
  end

  local function without_animation(fn)
    saved_animation = package.loaded["animation"]
    package.loaded["animation"] = nil
    package.preload["animation"] = function()
      error("animation.nvim not installed")
    end
    local ok, err = pcall(fn)
    package.preload["animation"] = nil
    package.loaded["animation"] = saved_animation
    assert(ok, err)
  end

  setup(function()
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      local inst = open_float()
      inst.opts = { border = "rounded", row = 2, col = 10, width = 40, height = 10 }
      function inst:buf_valid()
        return vim.api.nvim_buf_is_valid(self.buf)
      end
      function inst:hide()
        if self.win and vim.api.nvim_win_is_valid(self.win) then
          vim.api.nvim_win_close(self.win, true)
        end
        self.win = nil
      end
      function inst:show() end
      function inst:focus() end
      function inst.close() end
      return inst
    end
  end)

  teardown(function()
    snacks.open = orig_open
  end)

  after_each(function()
    for _, e in pairs(state.table) do
      local i = e.inst
      if i and i._bar_anim then
        i._bar_anim:finish()
      end
      if i and i._pill_win and vim.api.nvim_win_is_valid(i._pill_win) then
        vim.api.nvim_win_close(i._pill_win, true)
      end
    end
    require("harness-decorators.term")._reset()
  end)

  local function lands_on_opts(inst)
    local o = inst.opts
    return vim.deep_equal({ row = o.row, col = o.col, width = o.width, height = o.height }, rect_of(inst.win))
  end

  local function move_off_spot(inst)
    vim.api.nvim_win_set_config(inst.win, { relative = "editor", row = 1, col = 1, width = 20, height = 5 })
  end

  it("a float resize (term.reset_layout) lands the float on its new rect", function()
    local term = require("harness-decorators.term")
    local inst = term.open("claude")
    move_off_spot(inst)
    term.reset_layout("claude")
    assert.is_true(vim.wait(3000, function()
      return lands_on_opts(inst)
    end, 10))
  end)

  it("a float resize (term.reset_layout) lands the float on its new rect without animation.nvim", function()
    without_animation(function()
      local term = require("harness-decorators.term")
      local inst = term.open("claude")
      move_off_spot(inst)
      term.reset_layout("claude")
      assert.is_true(lands_on_opts(inst))
    end)
  end)

  local function lands_in_dock(inst)
    local bar = inst._pill_win
    local cfg = vim.api.nvim_win_get_config(bar)
    return cfg.height == 1 and cfg.width == inst._bar_width
  end

  it("term.minimize lands the bar in the dock", function()
    local term = require("harness-decorators.term")
    local inst = term.open("claude")
    term.minimize("claude")
    assert.is_true(vim.wait(3000, function()
      return lands_in_dock(inst)
    end, 10))
  end)

  it("term.minimize lands the bar in the dock without animation.nvim", function()
    without_animation(function()
      local term = require("harness-decorators.term")
      local inst = term.open("claude")
      term.minimize("claude")
      assert.is_true(lands_in_dock(inst))
    end)
  end)

  describe("with a terminal in the float", function()
    local term = require("harness-decorators.term")
    local layout = require("harness-decorators.layout")
    local anims = require("harness-decorators.terminal-animations")
    local jobs, real_set, real_animate_resize, saved_anim_ms

    ---Start a job in the fake float's buffer, so the window shows a real terminal.
    local function make_terminal(inst)
      vim.api.nvim_buf_call(inst.buf, function()
        jobs[#jobs + 1] = vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
      end)
    end

    ---Count, per window, the nvim_win_set_config calls that change its width or height.
    local function count_sizes()
      local sizes = {}
      vim.api.nvim_win_set_config = function(w, cfg)
        local ok, old = pcall(vim.api.nvim_win_get_config, w)
        if ok and ((cfg.width and cfg.width ~= old.width) or (cfg.height and cfg.height ~= old.height)) then
          sizes[w] = (sizes[w] or 0) + 1
        end
        return real_set(w, cfg)
      end
      return sizes
    end

    before_each(function()
      jobs = {}
      real_set = vim.api.nvim_win_set_config
      real_animate_resize = anims.animate_resize
      saved_anim_ms = vim.env.NVIM_HARNESS_ANIMATION_MS
      vim.env.NVIM_HARNESS_ANIMATION_MS = nil
    end)

    after_each(function()
      vim.env.NVIM_HARNESS_ANIMATION_MS = saved_anim_ms
      vim.api.nvim_win_set_config = real_set
      anims.animate_resize = real_animate_resize
      for _, j in ipairs(jobs) do
        pcall(vim.fn.jobstop, j)
      end
    end)

    it(
      "Given a harness float, When <C-f> makes it fullscreen, Then its width grows over more than 2 frames and it lands on the fullscreen rect",
      function()
        assert.is_true(pcall(require, "animation"), "this case needs the real animation.nvim")
        local inst = term.open("claude")
        make_terminal(inst)
        local sizes = count_sizes()
        term.fullscreen_key(inst)
        local target = layout.fullscreen_rect()
        assert.is_true(
          vim.wait(3000, function()
            return vim.deep_equal(target, rect_of(inst.win))
          end, 10),
          "the float should land on the fullscreen rect"
        )
        assert.is_true((sizes[inst.win] or 0) > 2, ("width changed on %d frames"):format(sizes[inst.win] or 0))
      end
    )

    it(
      "Given a fullscreen harness float, When <C-f> retracts it, Then its size shrinks over more than 2 frames and it lands on its saved rect",
      function()
        assert.is_true(pcall(require, "animation"), "this case needs the real animation.nvim")
        local inst = term.open("claude")
        make_terminal(inst)
        term.fullscreen_key(inst)
        assert.is_true(vim.wait(3000, function()
          return vim.deep_equal(layout.fullscreen_rect(), rect_of(inst.win))
        end, 10))
        local sizes = count_sizes()
        term.fullscreen_key(inst)
        assert.is_true(
          vim.wait(3000, function()
            return lands_on_opts(inst)
          end, 10),
          "the float should land back on its saved rect"
        )
        assert.is_true((sizes[inst.win] or 0) > 2, ("size changed on %d frames"):format(sizes[inst.win] or 0))
      end
    )

    it(
      "Given two harness floats, When term.tile() moves them, Then each changes size at most twice and no move asks for smooth size",
      function()
        assert.is_true(pcall(require, "animation"), "this case needs the real animation.nvim")
        local copilot = term.open("copilot")
        local claude = term.open("claude")
        make_terminal(copilot)
        make_terminal(claude)
        vim.api.nvim_set_current_win(claude.win)
        local flags = {}
        anims.animate_resize = function(inst, rect, on_done, smooth)
          flags[#flags + 1] = smooth or false
          return real_animate_resize(inst, rect, on_done, smooth)
        end
        local sizes = count_sizes()
        term.tile()
        vim.wait(1000)
        assert.is_true(#flags > 0, "tiling should move at least one float")
        for _, f in ipairs(flags) do
          assert.is_false(f, "a tiling move must stay position-only")
        end
        for _, inst in ipairs({ claude, copilot }) do
          assert.is_true((sizes[inst.win] or 0) <= 2, ("size changed %d times"):format(sizes[inst.win] or 0))
        end
      end
    )
  end)
end)
