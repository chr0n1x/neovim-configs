-- The harness float's global mouse maps and editor autocmds are registered by term's setup on the
-- first term.open, not when the module is required: requiring it (park.lua does at startup) must not
-- take over the mouse.
describe("term setup registration", function()
  local snacks, orig_open
  local keys = { "<LeftMouse>", "<LeftDrag>", "<LeftRelease>", "<2-LeftMouse>" }

  local function harness_map(mode, lhs)
    local m = vim.fn.maparg(lhs, mode, false, true)
    return m and m.desc and (m.desc:find("harness float", 1, true) ~= nil) and m or nil
  end

  local function group_events()
    local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "HarnessTerminalAutoInsert" })
    local events = {}
    for _, c in ipairs(ok and cmds or {}) do
      if c.buffer == nil or c.buffer == 0 then
        events[c.event] = (events[c.event] or 0) + 1
      end
    end
    return events
  end

  local function fresh_term()
    for _, mode in ipairs({ "n", "t" }) do
      for _, lhs in ipairs(keys) do
        pcall(vim.keymap.del, mode, lhs)
      end
    end
    pcall(vim.api.nvim_del_augroup_by_name, "HarnessTerminalAutoInsert")
    require("harness-decorators.term")._reset()
    package.loaded["harness-decorators.term"] = nil
    package.loaded["harness-decorators.mouse"] = nil
    return require("harness-decorators.term")
  end

  setup(function()
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      local buf = vim.api.nvim_create_buf(false, true)
      return {
        buf = buf,
        opts = {},
        hide = function() end,
        show = function() end,
        focus = function() end,
        close = function() end,
        buf_valid = function(self)
          return vim.api.nvim_buf_is_valid(self.buf)
        end,
      }
    end
  end)

  teardown(function()
    snacks.open = orig_open
    local term = fresh_term()
    term.setup()
  end)

  it("Given a fresh require of term, Then no mouse key is mapped and no editor autocmd is registered", function()
    fresh_term()
    for _, mode in ipairs({ "n", "t" }) do
      for _, lhs in ipairs(keys) do
        assert.is_nil(harness_map(mode, lhs), mode .. " " .. lhs .. " mapped at require")
      end
    end
    assert.are.same({}, group_events())
  end)

  it(
    "Given a fresh require of term, When two harnesses open, Then the mouse keys and autocmds are registered once",
    function()
      local term = fresh_term()
      term.open("claude")
      term.open("maki")
      for _, mode in ipairs({ "n", "t" }) do
        for _, lhs in ipairs(keys) do
          local m = harness_map(mode, lhs)
          assert.is_not_nil(m, mode .. " " .. lhs .. " not mapped after open")
          assert.are.equal(1, m.expr)
        end
      end
      assert.are.same({ WinEnter = 1, FocusGained = 1, VimResized = 1 }, group_events())
      term._reset()
    end
  )

  it("Given setup already ran, When term.mouse is used, Then it is the mouse module's handler table", function()
    local term = fresh_term()
    term.setup()
    assert.are.equal(require("harness-decorators.mouse"), term.mouse)
    assert.are.equal("<LeftMouse>", term.mouse.press({ screenrow = 1, screencol = 1 }))
    term.mouse.release()
  end)
end)
