-- term.list() answers "which harnesses are live" for park.list and, through it, the <C-q> picker
-- (switch.collect_terminal_bufs). These pin what those callers see, and that dead records are
-- pruned when their buffer goes away rather than as a side effect of a list() query.
describe("term.list and its callers", function()
  local snacks, orig_open
  local state = require("harness-decorators.state")

  local function make_fake(buf)
    return {
      buf = buf,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
      buf_valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
    }
  end

  setup(function()
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    snacks.open = function()
      return make_fake(vim.api.nvim_create_buf(false, true))
    end
  end)

  teardown(function()
    snacks.open = orig_open
    require("harness-decorators.term")._reset()
  end)

  before_each(function()
    require("harness-decorators.term")._reset()
  end)

  it("Given one live and one exited harness, park.list and collect_terminal_bufs list only the live one", function()
    local term = require("harness-decorators.term")
    local park = require("harness-decorators.park")
    local switch = require("harness-decorators.switch")
    local live = term.open("claude")
    local dead = term.open("maki")
    vim.api.nvim_buf_delete(dead.buf, { force = true })

    local entries = park.list()
    assert.are.equal(1, #entries)
    assert.are.equal("claude", entries[1].harness)
    assert.are.equal(live.buf, entries[1].buff_nr)
    assert.are.same({ claude = live.buf }, switch.collect_terminal_bufs())
  end)

  it("Given an exited harness's buffer is wiped, Then its record is pruned without any list() call", function()
    local term = require("harness-decorators.term")
    local dead = term.open("maki")
    vim.api.nvim_buf_delete(dead.buf, { force = true })
    assert.is_nil(state.table["maki"])
  end)

  it("Given a record whose instance is dead, When list(), Then the table is left untouched", function()
    local term = require("harness-decorators.term")
    local buf = vim.api.nvim_create_buf(false, true)
    local e = state.entry("maki")
    e.inst = make_fake(buf)
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.are.same({}, term.list())
    assert.are.equal(e, state.table["maki"])
  end)

  it("prune() drops exited records and keeps never-opened ones", function()
    local term = require("harness-decorators.term")
    local buf = vim.api.nvim_create_buf(false, true)
    state.entry("maki").inst = make_fake(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    local claude = state.entry("claude")

    term.prune()
    assert.is_nil(state.table["maki"])
    assert.are.equal(claude, state.table["claude"])
  end)
end)
