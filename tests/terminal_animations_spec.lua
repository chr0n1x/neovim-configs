-- Pins terminal-animations.animate_win's cost and timing contract. A move resizes the window (and
-- so the terminal inside it, which sends the harness SIGWINCH and makes it redraw) at most twice:
-- position is animated, size is applied in one step.
describe("terminal-animations: animate_win", function()
  local anims = require("harness-decorators.terminal-animations")
  local saved_set, saved_anim, wins, jobs

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
    saved_set = vim.api.nvim_win_set_config
    saved_anim = package.loaded["animation"]
    wins, jobs = {}, {}
    vim.o.columns, vim.o.lines = math.max(vim.o.columns, 120), math.max(vim.o.lines, 40)
  end)

  after_each(function()
    vim.api.nvim_win_set_config = saved_set
    package.loaded["animation"] = saved_anim
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
