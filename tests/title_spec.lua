-- Spec for harness title colors (title.lua): the HarnessTitle<Name> group each harness's picker row
-- and float title use.

local title = require("harness-decorators.title")

describe("harness title colors", function()
  it("Given the pig harness, When its title group is defined, Then it uses the idle-checkmark green", function()
    local group = title.define("pig")
    assert.are.equal("HarnessTitlePig", group)
    assert.are.equal(0x3ddc6e, vim.api.nvim_get_hl(0, { name = group }).fg)
  end)
end)

describe("harness title groups (pinned colors)", function()
  local expected = {
    claude = { "HarnessTitleClaude", 0xf0965f },
    maki = { "HarnessTitleMaki", 0x6eb9f0 },
    copilot = { "HarnessTitleCopilot", 0xaa78ff },
    crush = { "HarnessTitleCrush", 0xff60ff },
    pi = { "HarnessTitlePi", 0xffffff },
    pig = { "HarnessTitlePig", 0x3ddc6e },
  }

  for name, want in pairs(expected) do
    it(
      ("Given %s, When its title group is defined, Then it is %s with fg %06x"):format(name, want[1], want[2]),
      function()
        local group = title.define(name)
        assert.are.equal(want[1], group)
        assert.are.equal(want[2], vim.api.nvim_get_hl(0, { name = group }).fg)
        assert.are.same({ { " " .. name:sub(1, 1):upper() .. name:sub(2) .. " ", want[1] } }, title.title(name))
      end
    )
  end

  it("Given an unknown harness, When defined or titled, Then define is nil and title is the padded text", function()
    assert.is_nil(title.define("nosuch"))
    assert.are.equal(" Nosuch ", title.title("nosuch"))
  end)

  it("Given cleared groups, When define_all runs, Then all six groups and the not-installed group exist", function()
    for _, want in pairs(expected) do
      vim.api.nvim_set_hl(0, want[1], {})
    end
    vim.api.nvim_set_hl(0, title.picker_not_installed_group, {})
    title.define_all()
    for name, want in pairs(expected) do
      assert.are.equal(want[2], vim.api.nvim_get_hl(0, { name = want[1] }).fg, name)
    end
    assert.are.equal("HarnessPickerNotInstalled", title.picker_not_installed_group)
    assert.are.equal(0x5b6270, vim.api.nvim_get_hl(0, { name = title.picker_not_installed_group }).fg)
  end)
end)

describe("title color lookup fails fast for real harnesses", function()
  local MOD = "harness-decorators.claude"

  it("Given claude's adapter raises on load, When its title is defined, Then the error propagates", function()
    local saved = package.loaded[MOD]
    package.loaded[MOD] = nil
    package.preload[MOD] = function()
      error("boom: adapter failed to load")
    end
    local ok, err = pcall(title.define, "claude")
    package.preload[MOD] = nil
    package.loaded[MOD] = saved
    assert.is_false(ok, "define must not swallow a real harness's load error")
    assert.truthy(tostring(err):find("boom", 1, true), tostring(err))
  end)

  it("Given an unknown harness, When defined, Then it is nil without raising", function()
    assert.is_nil(title.define("nosuch"))
  end)
end)

describe("define_all with one broken adapter", function()
  local MOD = "harness-decorators.claude"
  local groups = {
    copilot = { "HarnessTitleCopilot", 0xaa78ff },
    crush = { "HarnessTitleCrush", 0xff60ff },
    maki = { "HarnessTitleMaki", 0x6eb9f0 },
    pi = { "HarnessTitlePi", 0xffffff },
    pig = { "HarnessTitlePig", 0x3ddc6e },
  }

  it(
    "Given claude's adapter raises on load, When define_all runs, Then it raises and still defines every other group",
    function()
      for _, g in pairs(groups) do
        vim.api.nvim_set_hl(0, g[1], {})
      end
      vim.api.nvim_set_hl(0, title.picker_not_installed_group, {})
      vim.api.nvim_set_hl(0, "TelescopeSelection", {})

      local saved = package.loaded[MOD]
      package.loaded[MOD] = nil
      package.preload[MOD] = function()
        error("boom: adapter failed to load")
      end
      local ok, err = pcall(title.define_all)
      package.preload[MOD] = nil
      package.loaded[MOD] = saved

      assert.is_false(ok, "define_all must re-raise the adapter's load error")
      assert.truthy(tostring(err):find("boom", 1, true), tostring(err))
      for name, g in pairs(groups) do
        assert.are.equal(g[2], vim.api.nvim_get_hl(0, { name = g[1] }).fg, name .. " group must still be defined")
      end
      assert.are.equal(0x5b6270, vim.api.nvim_get_hl(0, { name = title.picker_not_installed_group }).fg)
      assert.are.equal("Visual", vim.api.nvim_get_hl(0, { name = "TelescopeSelection" }).link)
    end
  )
end)

describe("a harness adapter without title_color", function()
  local MOD = "harness-decorators.pig"

  it("Given pig's adapter has no title_color, When titled, Then define is nil and title is the padded text", function()
    local saved = package.loaded[MOD]
    package.loaded[MOD] = setmetatable({}, { __index = require("harness-decorators.stub-adapter") })
    local ok, group, text = pcall(function()
      return title.define("pig"), title.title("pig")
    end)
    local all_ok, all_err = pcall(title.define_all)
    package.loaded[MOD] = saved
    assert.is_true(ok, tostring(group))
    assert.is_nil(group)
    assert.are.equal(" Pig ", text)
    assert.is_true(all_ok, tostring(all_err))
  end)
end)
