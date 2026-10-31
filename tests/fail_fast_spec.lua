-- In-repo modules are required without pcall, so a load error in one of them reaches the caller
-- instead of silently disabling a feature. Each case swaps the module's loader for one that
-- raises, drives the caller, and restores the loader.

local function failing_require(module, callback)
  local loaded, preload = package.loaded[module], package.preload[module]
  package.loaded[module] = nil
  package.preload[module] = function()
    error("broken owned module")
  end
  local ok, err = pcall(callback)
  package.loaded[module], package.preload[module] = loaded, preload
  assert.is_false(ok, "an owned module load error must reach the caller")
  assert.is_truthy(tostring(err):find("broken owned module", 1, true), tostring(err))
end

describe("edit-jump module load errors", function()
  local edit_jump = require("harness-decorators.edit-jump")
  local orig_defer, path

  before_each(function()
    -- Run the jump's deferred steps inline so their errors reach on_edit's caller.
    orig_defer = vim.defer_fn
    vim.defer_fn = function(fn)
      fn()
    end
    path = vim.fn.tempname() .. "-fail-fast.txt"
    vim.fn.writefile({ "one", "two", "three" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end)

  after_each(function()
    vim.defer_fn = orig_defer
    edit_jump.edit_sources = {}
    pcall(vim.cmd, "bwipeout! " .. vim.fn.fnameescape(path))
    vim.fn.delete(path)
  end)

  it("Given a broken focus module, When an edit jump runs, Then the load error is raised", function()
    failing_require("harness-decorators.focus", function()
      edit_jump.on_edit({ data = { file_path = path, starting_line = 2 } })
    end)
  end)

  it("Given a broken terminal module, When an edit jump sets the cursor, Then the load error is raised", function()
    failing_require("harness-decorators.term", function()
      edit_jump.on_edit({ data = { file_path = path, starting_line = 2 } })
    end)
  end)
end)

describe("utils module load errors", function()
  it(
    "Given a broken adapter for the active harness, When a session id is extracted, Then the load error is raised",
    function()
      local utils = require("harness-decorators.utils")
      local active = require("harness-decorators.active")
      local orig = active.get()
      active.set("claude")
      failing_require("harness-decorators.claude", function()
        utils.extract_session_id("/home/u/.claude/projects/x/abc.jsonl")
      end)
      active.set(orig)
    end
  )
end)

describe("zen-mode plugin module load errors", function()
  it("Given a broken focus module, When :ZenMode runs from a float, Then the load error is raised", function()
    require("zen-mode")
    local buf = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 10, height = 3 })
    failing_require("harness-decorators.focus", function()
      vim.cmd("ZenMode")
    end)
    pcall(vim.api.nvim_win_close, float, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe("lualine plugin module load errors", function()
  local saved = {}

  before_each(function()
    saved.spec = package.loaded["plugins.lualine"]
    saved.sections = LUALINE_SECTIONS
    package.loaded["plugins.lualine"] = nil
  end)

  after_each(function()
    package.loaded["plugins.lualine"] = saved.spec
    LUALINE_SECTIONS = saved.sections
  end)

  ---Build the lualine opts from a fresh copy of the spec with a stand-in agent-display, so no poll
  ---timer starts; returns the session and agents component functions.
  local function components()
    local display_mod = "harness-decorators.agent-display"
    local real = package.loaded[display_mod]
    package.loaded[display_mod] = {
      spinner = { "x" },
      start_timer = function() end,
      setup_highlights = function() end,
      component = function()
        return ""
      end,
    }
    local spec = require("plugins.lualine")
    local opts = {}
    spec.opts(nil, opts)
    package.loaded[display_mod] = real
    return opts.sections.lualine_x[1][1], opts.sections.lualine_y[1][1]
  end

  it("Given a broken agent-display module, When the lualine spec loads, Then the load error is raised", function()
    failing_require("harness-decorators.agent-display", function()
      require("plugins.lualine")
    end)
  end)

  it(
    "Given a broken harness-decorators module, When the session slot renders, Then the load error is raised",
    function()
      local session = components()
      failing_require("harness-decorators", session)
    end
  )

  it("Given a broken agent-display module, When the agents slot renders, Then the load error is raised", function()
    local _, agents = components()
    failing_require("harness-decorators.agent-display", agents)
  end)
end)
