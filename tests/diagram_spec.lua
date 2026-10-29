-- Spec for plugins/diagram.lua. image.nvim ships a rockspec, which gives it a top-level lazy.nvim
-- spec of its own; without an explicit lazy flag that spec loads it at startup instead of with
-- diagram.nvim on the first markdown buffer.

describe("plugins: diagram.nvim and image.nvim", function()
  local plugins = require("lazy.core.config").plugins

  it("Given the full config, When image.nvim is loaded, Then diagram.nvim loaded it, not startup", function()
    local image = plugins["image.nvim"]
    assert.is_not_nil(image, "image.nvim must be in the plugin spec")
    assert.is_true(image.lazy, "image.nvim must be lazy")
    -- Earlier specs in the same run may have opened markdown buffers, so it can already be loaded.
    local loaded = image._.loaded
    if loaded then
      assert.are.equal("diagram.nvim", loaded.plugin, "image.nvim must load only through diagram.nvim")
    end
  end)

  it("Given the full config, Then image.nvim is a dependency of diagram.nvim, which loads on markdown", function()
    local diagram = plugins["diagram.nvim"]
    assert.is_not_nil(diagram, "diagram.nvim must be in the plugin spec")
    assert.is_true(vim.tbl_contains(diagram.dependencies or {}, "image.nvim"))
    assert.is_true(vim.tbl_contains(diagram.ft or {}, "markdown"))
  end)
end)
