-- When a harness's terminal buffer is wiped (its process exited and Snacks dropped the buffer), its
-- record goes away. A minimized harness also owns a bar window; it must go with the record, since
-- the bar's mouse handlers can only find it through the record.
describe("wiping a harness's terminal buffer", function()
  local state = require("harness-decorators.state")
  local snacks, orig_open

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

  local function bar_valid(win)
    return win ~= nil and vim.api.nvim_win_is_valid(win)
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
  end)

  it(
    "Given a minimized harness, When its terminal buffer is wiped, Then its record and its bar are both gone, and a fresh open leaves one usable harness",
    function()
      local term = require("harness-decorators.term")
      local inst = term.open("claude")
      assert.is_true(term.minimize("claude"))
      local bar = inst._pill_win
      assert.is_true(bar_valid(bar), "precondition: the bar is docked")

      vim.api.nvim_buf_delete(inst.buf, { force = true })

      assert.is_nil(state.table["claude"], "the record must be pruned")
      assert.is_false(bar_valid(bar), "the bar must close with its record")
      assert.is_nil(inst._bar_anim, "the bar animation must be stopped")

      local fresh = term.open("claude")
      assert.are_not.equal(inst, fresh)
      assert.are.equal(fresh.buf, term.bufnr("claude"))
      assert.are.same(
        { "claude" },
        vim.tbl_map(function(e)
          return e.harness
        end, require("harness-decorators.park").list())
      )
    end
  )

  it(
    "Given an old instance whose record was replaced, When the old buffer is wiped, Then the replacement's record and bar are untouched",
    function()
      local term = require("harness-decorators.term")
      local old = term.open("claude")
      assert.is_true(term.minimize("claude"))
      local old_bar = old._pill_win
      state.table["claude"] = nil
      local new = term.open("claude")
      assert.is_true(term.minimize("claude"))
      local new_bar = new._pill_win

      vim.api.nvim_buf_delete(old.buf, { force = true })

      assert.are.equal(new, state.table["claude"].inst, "the replacement record stays")
      assert.is_true(bar_valid(new_bar), "the replacement's bar stays")
      assert.is_false(bar_valid(old_bar), "the old instance's own bar closes")
    end
  )
end)
