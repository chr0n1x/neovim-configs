-- Pins a clean start of the full config in the test container: lazy.nvim has nothing left to
-- install or build, startup reported no error, and the markdown parser that render-markdown needs
-- loads. A startup error here surfaces inside whichever spec first turns the event loop.

describe("test container startup", function()
  it("Given the full config loaded, Then lazy has no plugin left to install or build", function()
    local pending = {}
    for name, plugin in pairs(require("lazy.core.config").plugins) do
      if not plugin._.installed or plugin._.build then
        pending[#pending + 1] = name
      end
    end
    table.sort(pending)
    assert.are.same({}, pending)
  end)

  it("Given the full config loaded, Then startup reported no missing plugins and no error", function()
    local messages = vim.fn.execute("messages")
    assert.is_nil(messages:find("Too many rounds of missing plugins", 1, true), messages)
    assert.is_nil(messages:find("Error", 1, true), messages)
  end)

  it("Given a markdown buffer, Then the markdown parsers load", function()
    assert.is_true(vim.treesitter.language.add("markdown") == true, "no markdown parser")
    assert.is_true(vim.treesitter.language.add("markdown_inline") == true, "no markdown_inline parser")
  end)
end)
