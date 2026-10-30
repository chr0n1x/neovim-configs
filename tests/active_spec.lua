-- Spec for the active-harness owner (harness-decorators.active): one value, seeded from
-- $NVIM_LLM_HARNESS, with ordered subscribers that each run in their own pcall.
local utils = require("harness-decorators.utils")

describe("active harness owner", function()
  local orig_env
  local orig_loaded

  local function fresh_load(env)
    vim.fn.setenv("NVIM_LLM_HARNESS", env)
    package.loaded["harness-decorators.active"] = nil
    return require("harness-decorators.active")
  end

  before_each(function()
    orig_env = os.getenv("NVIM_LLM_HARNESS")
    orig_loaded = package.loaded["harness-decorators.active"]
  end)

  after_each(function()
    vim.fn.setenv("NVIM_LLM_HARNESS", orig_env or vim.NIL)
    package.loaded["harness-decorators.active"] = orig_loaded
  end)

  it("Given NVIM_LLM_HARNESS=maki, When the module loads fresh, Then get() is maki", function()
    assert.are.equal("maki", fresh_load("maki").get())
  end)

  it("Given NVIM_LLM_HARNESS names no harness, When the module loads fresh, Then get() is claude", function()
    assert.are.equal("claude", fresh_load("bogus").get())
  end)

  it("Given NVIM_LLM_HARNESS is unset, When the module loads fresh, Then get() is claude", function()
    assert.are.equal("claude", fresh_load(vim.NIL).get())
  end)

  it("Given set(copilot), When get(), Then copilot and no subscriber runs", function()
    local active = fresh_load("claude")
    local ran = false
    active.subscribe("a", function()
      ran = true
    end)
    active.set("copilot")
    assert.are.equal("copilot", active.get())
    assert.is_false(ran)
  end)

  it("Given subscribers a then b, When notify, Then they run in order with (new, old)", function()
    local active = fresh_load("claude")
    local calls = {}
    active.subscribe("a", function(new, old)
      calls[#calls + 1] = "a:" .. new .. ":" .. old
    end)
    active.subscribe("b", function(new, old)
      calls[#calls + 1] = "b:" .. new .. ":" .. old
    end)
    active.notify("copilot", "claude")
    assert.are.same({ "a:copilot:claude", "b:copilot:claude" }, calls)
  end)

  it("Given subscriber a throws, When notify, Then b still runs, get() is unchanged and {a} is returned", function()
    local active = fresh_load("claude")
    active.set("copilot")
    local b_ran = false
    active.subscribe("a", function()
      error("boom")
    end)
    active.subscribe("b", function()
      b_ran = true
    end)
    local orig_log = utils.log
    local logged = {}
    utils.log = function(msg, level)
      logged[#logged + 1] = { msg = msg, level = level }
    end
    local failed = active.notify("copilot", "claude")
    utils.log = orig_log
    assert.is_true(b_ran)
    assert.are.equal("copilot", active.get())
    assert.are.same({ "a" }, failed)
    assert.are.equal(1, #logged)
    assert.truthy(logged[1].msg:find("activate: a failed", 1, true))
    assert.are.equal(vim.log.levels.WARN, logged[1].level)
  end)

  it(
    "Given the same id subscribed twice, When notify, Then only the second callback runs, in the first position",
    function()
      local active = fresh_load("claude")
      local calls = {}
      active.subscribe("a", function()
        calls[#calls + 1] = "a1"
      end)
      active.subscribe("b", function()
        calls[#calls + 1] = "b"
      end)
      active.subscribe("a", function()
        calls[#calls + 1] = "a2"
      end)
      active.notify("copilot", "claude")
      assert.are.same({ "a2", "b" }, calls)
    end
  )
end)
