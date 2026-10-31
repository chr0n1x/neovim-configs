-- Pins terminal-animations.animate_win's cost and timing contract. By default a move resizes a
-- terminal window (and so the terminal inside it, which sends the harness SIGWINCH and makes it
-- redraw) at most twice: position is animated, size is applied in one step. With smooth_size it
-- interpolates the size every frame, as it does for any other window. NVIM_HARNESS_ANIMATION_MS sets
-- the duration, read at call time; 0 jumps straight to the target.
describe("terminal-animations: animate_win", function()
  local anims = require("harness-decorators.terminal-animations")
  local VAR = "NVIM_HARNESS_ANIMATION_MS"
  local saved_var, saved_set, saved_anim, wins, jobs

  ---A float showing a live terminal job, so a size change really resizes a terminal.
  local function terminal_float(rect)
    local buf = vim.api.nvim_create_buf(false, true)
    local cfg = vim.tbl_extend("force", { relative = "editor", style = "minimal" }, rect)
    local win = vim.api.nvim_open_win(buf, false, cfg)
    vim.api.nvim_buf_call(buf, function()
      jobs[#jobs + 1] = vim.fn.jobstart({ "sh", "-c", "sleep 30" }, { term = true })
    end)
    wins[#wins + 1] = win
    return win
  end

  ---Count nvim_win_set_config calls on `win`, and the ones that change its width or height.
  local function count_configs(win)
    local c = { calls = 0, size = 0, rects = {} }
    vim.api.nvim_win_set_config = function(w, cfg)
      if w == win then
        local old = vim.api.nvim_win_get_config(w)
        c.calls = c.calls + 1
        if (cfg.width and cfg.width ~= old.width) or (cfg.height and cfg.height ~= old.height) then
          c.size = c.size + 1
        end
        c.rects[#c.rects + 1] = { width = cfg.width or old.width, height = cfg.height or old.height }
      end
      return saved_set(w, cfg)
    end
    return c
  end

  local function rect_of(win)
    local cfg = vim.api.nvim_win_get_config(win)
    return { row = math.floor(cfg.row), col = math.floor(cfg.col), width = cfg.width, height = cfg.height }
  end

  before_each(function()
    saved_var = os.getenv(VAR)
    vim.env[VAR] = nil
    saved_set = vim.api.nvim_win_set_config
    saved_anim = package.loaded["animation"]
    wins, jobs = {}, {}
    vim.o.columns, vim.o.lines = math.max(vim.o.columns, 120), math.max(vim.o.lines, 40)
  end)

  after_each(function()
    vim.api.nvim_win_set_config = saved_set
    package.loaded["animation"] = saved_anim
    package.preload["animation"] = nil
    vim.env[VAR] = saved_var
    for _, j in ipairs(jobs) do
      pcall(vim.fn.jobstop, j)
    end
    for _, w in ipairs(wins) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        pcall(vim.api.nvim_win_close, w, true)
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)

  for _, case in ipairs({
    {
      name = "grows and moves",
      from = { row = 1, col = 1, width = 20, height = 5 },
      to = { row = 10, col = 40, width = 70, height = 25 },
    },
    {
      name = "shrinks and moves",
      from = { row = 2, col = 50, width = 60, height = 25 },
      to = { row = 12, col = 4, width = 18, height = 6 },
    },
    {
      name = "shrinks in width and grows in height",
      from = { row = 3, col = 10, width = 70, height = 6 },
      to = { row = 1, col = 30, width = 25, height = 30 },
    },
  }) do
    it(
      ("Given a terminal float that %s, When animated with animation.nvim, Then its size changes at most twice, it lands on the target and on_done runs once"):format(
        case.name
      ),
      function()
        assert.is_true(pcall(require, "animation"), "these cases need the real animation.nvim")
        local win = terminal_float(case.from)
        local c = count_configs(win)
        local done = 0
        anims.animate_win({}, "_anim", win, case.to, nil, function()
          done = done + 1
        end)
        assert.is_true(
          vim.wait(3000, function()
            return done > 0
          end, 10),
          "the animation never landed"
        )
        vim.wait(100)
        assert.are.equal(1, done)
        assert.are.same(case.to, rect_of(win))
        assert.is_true(c.calls > 2, "a 300ms move should still animate its position")
        assert.is_true(c.size <= 2, ("size changed %d times in %d frames"):format(c.size, c.calls))
        for _, r in ipairs(c.rects) do
          assert.is_true(
            r.width <= math.max(case.from.width, case.to.width)
              and r.height <= math.max(case.from.height, case.to.height),
            "a frame covered more than the larger of the two rects: " .. vim.inspect(r)
          )
        end
      end
    )
  end

  it(
    "Given a terminal float and smooth_size, When animated with animation.nvim, Then its size changes on more than 2 frames, it lands on the target and on_done runs once",
    function()
      assert.is_true(pcall(require, "animation"), "this case needs the real animation.nvim")
      local from = { row = 2, col = 10, width = 40, height = 10 }
      local to = { row = 1, col = 4, width = 100, height = 30 }
      local win = terminal_float(from)
      local c = count_configs(win)
      local done = 0
      anims.animate_win({}, "_anim", win, to, nil, function()
        done = done + 1
      end, true)
      assert.is_true(
        vim.wait(3000, function()
          return done > 0
        end, 10),
        "the animation never landed"
      )
      vim.wait(100)
      assert.are.equal(1, done)
      assert.are.same(to, rect_of(win))
      assert.is_true(c.size > 2, ("smooth_size should resize every frame, got %d size changes"):format(c.size))
    end
  )

  it(
    "Given NVIM_HARNESS_ANIMATION_MS=0, When a float moves, Then it lands with one set_config and on_done runs synchronously",
    function()
      vim.env[VAR] = "0"
      local win = terminal_float({ row = 1, col = 1, width = 20, height = 5 })
      local c = count_configs(win)
      local done = 0
      local to = { row = 8, col = 30, width = 50, height = 20 }
      assert.is_true(anims.animate_win({}, "_anim", win, to, nil, function()
        done = done + 1
      end))
      assert.are.equal(1, done)
      assert.are.equal(1, c.calls)
      assert.are.same(to, rect_of(win))
      vim.wait(400)
      assert.are.equal(1, done)
      assert.are.equal(1, c.calls)
    end
  )

  ---Run one move with an animation.nvim stand-in and return the duration it was built with.
  local function duration_used()
    local got
    package.loaded["animation"] = function(duration)
      got = duration
      return { run = function() end, finish = function() end }
    end
    local win = terminal_float({ row = 1, col = 1, width = 20, height = 5 })
    anims.animate_win({}, "_anim", win, { row = 2, col = 2, width = 30, height = 6 })
    return got
  end

  it("Given NVIM_HARNESS_ANIMATION_MS unset, When a float moves, Then the animation runs for 300ms", function()
    assert.are.equal(300, duration_used())
  end)

  it("Given NVIM_HARNESS_ANIMATION_MS=150, When a float moves, Then the animation runs for 150ms", function()
    vim.env[VAR] = "150"
    assert.are.equal(150, duration_used())
  end)

  for _, value in ipairs({ "fast", "", "-5" }) do
    it(("Given NVIM_HARNESS_ANIMATION_MS=%q, When a float moves, Then it falls back to 300ms"):format(value), function()
      vim.env[VAR] = value
      assert.are.equal(300, duration_used())
    end)
  end

  it(
    "Given no animation.nvim and NVIM_HARNESS_ANIMATION_MS=150, When a float moves, Then it jumps to the target and on_done runs once, synchronously",
    function()
      vim.env[VAR] = "150"
      package.loaded["animation"] = nil
      package.preload["animation"] = function()
        error("animation.nvim not installed")
      end
      local win = terminal_float({ row = 1, col = 1, width = 20, height = 5 })
      local done = 0
      local to = { row = 5, col = 9, width = 40, height = 12 }
      anims.animate_win({}, "_anim", win, to, nil, function()
        done = done + 1
      end)
      assert.are.equal(1, done)
      assert.are.same(to, rect_of(win))
    end
  )

  it(
    "Given a float showing a plain buffer (a minimized bar), When it grows, Then its size grows during the animation",
    function()
      assert.is_true(pcall(require, "animation"), "this case needs the real animation.nvim")
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 60, width = 10, height = 1 })
      wins[#wins + 1] = win
      local c = count_configs(win)
      local done = 0
      local to = { row = 5, col = 10, width = 50, height = 12 }
      anims.animate_win({}, "_anim", win, to, nil, function()
        done = done + 1
      end)
      assert.is_true(vim.wait(3000, function()
        return done > 0
      end, 10))
      assert.are.same(to, rect_of(win))
      assert.is_true(c.size > 2, ("a bar should resize smoothly, got %d size changes"):format(c.size))
    end
  )
end)
