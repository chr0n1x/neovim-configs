describe("keymap callbacks: terminal entry points", function()
  local keymaps = require("harness-decorators.keymaps")
  local term = require("harness-decorators.term")
  local park = require("harness-decorators.park")
  local state = require("harness-decorators.state")
  local active = require("harness-decorators.active")
  local switch = require("harness-decorators.switch")
  local focus = require("harness-decorators.focus")
  local harnesses = require("harness-decorators")
  local watcher = require("harness-decorators.watcher")
  local snacks = require("snacks.terminal")
  local saved, callbacks, buffers

  before_each(function()
    saved = {
      records = state.table,
      active = active.get(),
      command = package.loaded["harness-decorators.claude.env"],
      snacks_open = snacks.open,
      term_open = term.open,
      suppress = focus.suppress_next_leave,
      restore = focus.restore,
      show = park.show_selected,
      follow = harnesses.setup_auto_follow,
      watcher_start = watcher.start,
      watcher_reset = watcher.reset_pin_state,
      schedule = vim.schedule,
    }
    state._reset()
    switch.init("claude")
    buffers, callbacks = {}, {}
    for _, spec in ipairs(keymaps.build("claude")) do
      callbacks[spec[1]] = spec[2]
    end
    package.loaded["harness-decorators.claude.env"] = {
      command = function()
        return "keymap-pin-command"
      end,
      prepare_env = function()
        return {}
      end,
    }
    -- A paused follow lifecycle can resume during open; these pins exercise command routing instead.
    watcher.start = function() end
    watcher.reset_pin_state = function() end
  end)

  after_each(function()
    snacks.open, term.open = saved.snacks_open, saved.term_open
    focus.suppress_next_leave, focus.restore = saved.suppress, saved.restore
    park.show_selected, harnesses.setup_auto_follow = saved.show, saved.follow
    watcher.start, watcher.reset_pin_state = saved.watcher_start, saved.watcher_reset
    vim.schedule = saved.schedule
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    state.table = saved.records
    active.set(saved.active)
    package.loaded["harness-decorators.claude.env"] = saved.command
  end)

  it(
    "Given a fresh harness, When its continue callback runs twice, Then Snacks receives --continue once and the live instance is reused",
    function()
      local commands = {}
      snacks.open = function(cmd)
        commands[#commands + 1] = cmd
        local buf = vim.api.nvim_create_buf(false, true)
        buffers[#buffers + 1] = buf
        return {
          buf = buf,
          opts = {},
          show = function() end,
          buf_valid = function(self)
            return vim.api.nvim_buf_is_valid(self.buf)
          end,
        }
      end
      assert.is_function(callbacks["<leader>cc"])
      assert.is_nil(term.bufnr("claude"), "precondition: no live instance")

      callbacks["<leader>cc"]()
      local first = state.table.claude.inst
      assert.are.same({ "keymap-pin-command --continue" }, commands)
      assert.is_true(vim.api.nvim_buf_is_valid(first.buf))
      assert.are.equal(first.buf, term.bufnr("claude"))

      callbacks["<leader>cc"]()
      assert.are.same({ "keymap-pin-command --continue" }, commands)
      assert.are.equal(first, state.table.claude.inst)
      assert.are.equal(first.buf, term.bufnr("claude"))
    end
  )

  it(
    "Given the focus callback, When it runs, Then capture is suppressed before restoring the work buffer and showing the selected harness",
    function()
      local calls, pending = {}, {}
      vim.schedule = function(callback)
        pending[#pending + 1] = callback
      end
      harnesses.setup_auto_follow = function() end
      focus.suppress_next_leave = function()
        calls[#calls + 1] = "suppress"
      end
      focus.restore = function()
        calls[#calls + 1] = "restore"
      end
      park.show_selected = function()
        calls[#calls + 1] = "show_selected"
      end
      assert.is_function(callbacks["<leader>c"])

      callbacks["<leader>c"]()

      assert.are.same({ "suppress", "restore", "show_selected" }, calls)
      for _, callback in ipairs(pending) do
        callback()
      end
    end
  )

  it("Given an open that returns nil, When park shows the selected harness, Then it returns nil", function()
    local attempted = {}
    term.open = function(harness)
      attempted[#attempted + 1] = harness
      return nil
    end

    assert.is_nil(park.show_selected())
    assert.are.same({ "claude" }, attempted, "the selected harness must reach the failed open")
  end)
end)
