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
