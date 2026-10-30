local ci = require("harness-decorators.context-inject")

describe("context-inject.line_range", function()
  it("is empty without both bounds", function()
    assert.are.equal("", ci.line_range(nil, nil))
    assert.are.equal("", ci.line_range(5, nil))
    assert.are.equal("", ci.line_range(nil, 9))
  end)

  it("is a single #L when start equals end", function()
    assert.are.equal("#L5", ci.line_range(5, 5))
  end)

  it("is #L<s>-<e> for a span", function()
    assert.are.equal("#L5-9", ci.line_range(5, 9))
  end)
end)

describe("context-inject.at_mention", function()
  local utils = require("harness-decorators.utils")

  it("prefixes @ and shortens a file path", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    assert.are.equal("@" .. utils.shorten_path(path), ci.at_mention(path))
    assert.are.equal("@" .. utils.shorten_path(path) .. "#L2-3", ci.at_mention(path, 2, 3))
  end)

  it("appends a trailing slash to directories", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir)
    local short = utils.shorten_path(dir)
    assert.are.equal("@" .. short .. "/", ci.at_mention(dir))
    assert.are.equal("@" .. short .. "/#L1", ci.at_mention(dir, 1, 1))
  end)
end)

describe("context-inject.type_into_terminal: PTY writes", function()
  local writes, notes, orig_chansend, orig_notify, chan_result

  before_each(function()
    require("harness-decorators.state")._reset()
    vim.cmd("only")
    vim.cmd("vsplit")
    vim.cmd("terminal cat")
    vim.cmd("stopinsert")
    writes, notes, chan_result = {}, {}, 1
    orig_chansend = vim.fn.chansend
    orig_notify = vim.notify
    vim.fn.chansend = function(_chan, data)
      table.insert(writes, data)
      return chan_result
    end
    vim.notify = function(msg, level)
      table.insert(notes, { message = tostring(msg), level = level })
    end
  end)

  after_each(function()
    vim.fn.chansend = orig_chansend
    vim.notify = orig_notify
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.cmd("only")
  end)

  it("appends one inline space to single-line text", function()
    assert.is_not_nil(ci.type_into_terminal("@a.lua", nil, "pig"))
    assert.are.same({ "@a.lua " }, writes)
  end)

  it("wraps multi-line text in bracketed-paste markers and normalizes line breaks", function()
    ci.type_into_terminal("one\r\ntwo\rthree", nil, "pig")
    assert.are.same({ "\27[200~one\ntwo\nthree\27[201~ " }, writes)
  end)

  it("adds no space when the text already ends in whitespace", function()
    ci.type_into_terminal("@a.lua ", nil, "pig")
    assert.are.same({ "@a.lua " }, writes)
  end)

  it("sends the space as its own write when separate_space is set", function()
    ci.type_into_terminal("@a.lua", { separate_space = true }, "pig")
    assert.are.same({ "@a.lua", " " }, writes)
  end)

  it("sends no extra space with separate_space when the text ends in whitespace", function()
    ci.type_into_terminal("@a.lua ", { separate_space = true }, "pig")
    assert.are.same({ "@a.lua " }, writes)
  end)

  it("wraps a bare newline separator in bracketed paste without a trailing space", function()
    ci.type_into_terminal("\n", nil, "pig")
    assert.are.same({ "\27[200~\n\27[201~" }, writes)
  end)

  it("warns and returns nil when the channel is closed", function()
    chan_result = 0
    assert.is_nil(ci.type_into_terminal("@a.lua", nil, "pig"))
    assert.is_truthy(notes[1] and notes[1].message:find("terminal channel is closed", 1, true))
    assert.are.equal(vim.log.levels.WARN, notes[1].level)
  end)
end)

describe("in-repo module load errors", function()
  local function failing_require(module, callback)
    local loaded, preload = package.loaded[module], package.preload[module]
    package.loaded[module] = nil
    package.preload[module] = function()
      error("broken owned module")
    end
    local ok, err = pcall(callback)
    package.loaded[module], package.preload[module] = loaded, preload
    assert.is_false(ok, "an owned module load error must reach the caller")
    assert.is_truthy(tostring(err):find("broken owned module", 1, true))
  end

  it("Given a broken terminal module, When context is sent, Then the load error is raised", function()
    failing_require("harness-decorators.term", function()
      ci.type_into_terminal("@a.lua", nil, "pig")
    end)
  end)

  it("Given a broken display module, When the overview key runs, Then the load error is raised", function()
    local specs = require("harness-decorators.keymaps").build("pig")
    failing_require("harness-decorators.agent-display", function()
      for _, spec in ipairs(specs) do
        if spec[1] == "<leader>co" then
          spec[2]()
        end
      end
    end)
  end)

  it("Given a broken state module, When the display refreshes, Then the load error is raised", function()
    local display = require("harness-decorators.agent-display")
    failing_require("harness-decorators.agent-state", display.refresh)
    failing_require("harness-decorators.agent-state", display.refresh_async)
  end)

  it("Given a broken display module, When the session slot renders, Then the load error is raised", function()
    local harnesses = require("harness-decorators")
    failing_require("harness-decorators.agent-display", function()
      harnesses.session_component(".")
    end)
  end)
end)
