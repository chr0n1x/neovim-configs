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
