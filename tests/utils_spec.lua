-- Unit specs for the shared harness-decorators.utils helpers and the context-inject
-- path shortener. These are the small, pure functions that underpin session pinning,
-- dedup, and cursor placement - a regression here silently breaks auto-follow for every
-- harness, so they get direct coverage independent of the watcher/adapter stack.

local utils = require("harness-decorators.utils")
local ci = require("harness-decorators.context-inject")

describe("utils.is_noise", function()
  it("rejects nil and empty paths", function()
    assert.is_true(utils.is_noise(nil))
    assert.is_true(utils.is_noise(""))
  end)

  -- is_noise returns the matched pattern (truthy) or nil, not a boolean - assert truthiness.
  it("flags temp, swap, backup, and /proc files", function()
    assert.is_truthy(utils.is_noise("/tmp/x.tmp"))
    assert.is_truthy(utils.is_noise("/tmp/x.tmp123"))
    assert.is_truthy(utils.is_noise("file.swp"))
    assert.is_truthy(utils.is_noise("file.swn"))
    assert.is_truthy(utils.is_noise("file~"))
    assert.is_truthy(utils.is_noise("/proc/1234/fd/0"))
  end)

  it("accepts ordinary source files", function()
    assert.is_falsy(utils.is_noise("/home/kran/Code/foo.lua"))
    assert.is_falsy(utils.is_noise("README.md"))
  end)
end)

describe("utils.clamp_line", function()
  it("returns nil for a non-number starting_line", function()
    assert.is_nil(utils.clamp_line(nil, 10))
    assert.is_nil(utils.clamp_line("3", 10))
  end)

  it("clamps into [1, max_line]", function()
    assert.are.equal(5, utils.clamp_line(5, 10)) -- in range
    assert.are.equal(10, utils.clamp_line(99, 10)) -- past EOF
    assert.are.equal(1, utils.clamp_line(0, 10)) -- below floor
    assert.are.equal(1, utils.clamp_line(-3, 10)) -- negative
  end)

  it("clamps to 1 for an empty buffer", function()
    assert.are.equal(1, utils.clamp_line(7, 0))
  end)
end)

describe("utils.extract_session_id", function()
  it("falls back to the filename stem for a <id>.jsonl path (claude/maki)", function()
    -- The active harness in CI is claude, which has no session_id adapter method, so the
    -- generic stem fallback applies: the id is the basename minus .jsonl.
    assert.are.equal("abc123", utils.extract_session_id("/home/u/.claude/projects/x/abc123.jsonl"))
  end)

  it("returns nil for a non-jsonl or nil path", function()
    assert.is_nil(utils.extract_session_id(nil))
    -- A path with no .jsonl suffix and no adapter override yields no stem.
    assert.is_nil(utils.extract_session_id("/home/u/somefile.txt"))
  end)

  it("uses the parent dir as the id for copilot's <id>/events.jsonl layout", function()
    -- Flip utils.harness to copilot so its session_id adapter method (parent-dir rule) is
    -- in play, then restore. We set the field directly rather than calling switch.switch:
    -- that restarts the watcher and re-points claudecode state, which a unit spec must not
    -- do. extract_session_id only reads utils.harness to pick the adapter.
    local orig = utils.harness
    utils.harness = "copilot"
    assert.are.equal("sess-42", utils.extract_session_id("/home/u/.copilot/sess-42/events.jsonl"))
    utils.harness = orig
  end)
end)

describe("utils.ownership_from_cwd (tri-state contract)", function()
  it("returns 'match' when the session cwd equals nvim's cwd", function()
    assert.are.equal("match", utils.ownership_from_cwd("/a/b", "/a/b"))
  end)

  it("returns 'mismatch' when a known cwd differs from nvim's cwd", function()
    assert.are.equal("mismatch", utils.ownership_from_cwd("/a/b", "/a/c"))
  end)

  it("returns 'unknown' when there is no cwd evidence yet (nil)", function()
    assert.are.equal("unknown", utils.ownership_from_cwd("/a/b", nil))
  end)
end)

describe("shorten_path (3-tier display rule, shared across callers)", function()
  local cwd = vim.uv.cwd()
  local home = vim.env.HOME

  it("returns a cwd-relative path for files under the current dir", function()
    local f = cwd .. "/lua/harness-decorators/utils.lua"
    assert.are.equal("lua/harness-decorators/utils.lua", utils.shorten_path(f))
  end)

  it("returns the full path when the file IS the cwd (no bare './' form)", function()
    assert.are.equal(cwd, utils.shorten_path(cwd))
  end)

  it("collapses to ~ for files under $HOME but not under cwd", function()
    -- Pick a home-relative path that is NOT under cwd. If cwd happens to be under home
    -- (it is), choose a sibling directory so the cwd-relative tier does not apply.
    local f = home .. "/elsewhere/file.lua"
    assert.are.equal("~/elsewhere/file.lua", utils.shorten_path(f))
  end)

  it("returns the full path for files outside both cwd and $HOME", function()
    assert.are.equal("/etc/hosts", utils.shorten_path("/etc/hosts"))
  end)

  it("context-inject.shorten_path delegates to the shared definition (no divergence)", function()
    -- The four harness keymaps call ci.shorten_path; it must produce exactly what the shared
    -- utils.shorten_path produces, so there is one source of truth for display shortening.
    local samples = {
      cwd .. "/lua/harness-decorators/utils.lua", -- cwd-relative tier
      home .. "/elsewhere/file.lua", -- ~ tier
      "/etc/hosts", -- absolute tier
      cwd, -- the cwd itself
    }
    for _, f in ipairs(samples) do
      assert.are.equal(utils.shorten_path(f), ci.shorten_path(f),
        ("ci.shorten_path diverged from utils.shorten_path for %q"):format(f))
    end
  end)
end)

describe("context-inject.type_into_terminal: no visible terminal opens OUR float, not claudecode's", function()
  local term_mod
  local orig_open
  local snacks
  local orig_snacks_open
  local opened_harnesses

  ---A fake Snacks instance backed by a real terminal window (so find_terminal_win succeeds after open).
  local function make_fake(win)
    local buf = vim.api.nvim_win_get_buf(win)
    -- Give the buffer a channel so type_into_terminal's send path finds one (chansend is stubbed, so the
    -- value is never actually used - it just has to be non-zero to pass the "no channel" guard).
    vim.b[buf].terminal_job_id = 1234
    return {
      buf = buf,
      win = win,
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
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    opened_harnesses = {}
    -- Stub Snacks.open so term.open's fresh-open path records the harness and hands back a fake backed
    -- by a real terminal window (vsplit + :terminal cat - the reliable headless path).
    orig_snacks_open = snacks.open
    snacks.open = function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= vim.api.nvim_get_current_win() then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
      vim.cmd("vsplit")
      local ok = pcall(vim.cmd, "terminal cat")
      assert.is_true(ok, "could not open a terminal window (cat)")
      local win = vim.api.nvim_get_current_win()
      vim.wait(100, function() return false end, 25)
      return make_fake(win)
    end
    -- Record which harness term.open is asked to open.
    orig_open = term_mod.open
    term_mod.open = function(harness, opts)
      table.insert(opened_harnesses, harness)
      return orig_open(harness, opts)
    end
  end)

  teardown(function()
    if term_mod and orig_open then
      term_mod.open = orig_open
    end
    if snacks and orig_snacks_open then
      snacks.open = orig_snacks_open
    end
    -- Close any terminal window/buffer the test opened so it does not leak into later specs.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end)

  it("with no visible terminal, opens the harness's OWN float via term.open (not ClaudeCodeOpen)", function()
    -- Ensure no terminal window is currently visible so find_terminal_win returns nil and the fallback
    -- runs. The whole point: the fallback must route through OUR term.open (per-harness Snacks float),
    -- NOT claudecode's stock ClaudeCodeOpen - which would spawn a second, claudecode-owned split pane.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
          pcall(vim.api.nvim_win_close, w, true)
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
    assert.is_nil(ci.find_terminal_win(), "precondition: no visible terminal window")

    -- Clear any per-harness instance a prior spec left behind, so term.open spawns FRESH (via our
    -- stubbed snacks.open) rather than re-showing a stale instance whose buffer has no channel.
    require("harness-decorators.state")._reset()

    -- Stub chansend so the (now-open) terminal's send path succeeds without a real PTY write.
    local orig_chansend = vim.fn.chansend
    vim.fn.chansend = function(_chan, _data) return 1 end

    -- Capture any notify so a failure surfaces the reason (e.g. "no terminal channel").
    local orig_notify = vim.notify
    local notes = {}
    vim.notify = function(msg) table.insert(notes, tostring(msg)) end

    local result = ci.type_into_terminal("@/tmp/somefile", nil, "claude")

    vim.fn.chansend = orig_chansend
    vim.notify = orig_notify

    assert.is_not_nil(result, "type_into_terminal must succeed after opening our float (notifies: "
      .. table.concat(notes, " | ") .. ")")
    assert.are.equal(1, #opened_harnesses, "the fallback must open a terminal exactly once")
    assert.are.equal("claude", opened_harnesses[1], "the fallback must open the HARNESS's own float (claude)")
  end)

  it("<C-t> tree-add with no visible terminal opens OUR float, not claudecode's", function()
    -- Same regression as <leader>ca but through the tree-add path: <C-t> in a tree buffer runs the
    -- harness's *TreeAdd command (e.g. ClaudeTreeAdd), which calls make_tree_add_command's handler ->
    -- type_into_terminal. With no terminal open, that fallback must open OUR per-harness float via
    -- term.open, NOT claudecode's stock ClaudeCodeOpen (which would spawn a second split pane). We stub
    -- get_tree_selection to return a real path and drive the user command directly.
    opened_harnesses = {} -- reset: shared across tests in this describe block
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
          pcall(vim.api.nvim_win_close, w, true)
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
    assert.is_nil(ci.find_terminal_win(), "precondition: no visible terminal window")

    require("harness-decorators.state")._reset()

    -- Stub the tree selection so the command has a path to send without a real tree buffer.
    local utils = require("harness-decorators.utils")
    local orig_gts = utils.get_tree_selection
    utils.get_tree_selection = function() return { "/tmp/somefile.txt" } end

    local orig_chansend = vim.fn.chansend
    vim.fn.chansend = function(_chan, _data) return 1 end

    local ok, err = pcall(vim.cmd, "ClaudeTreeAdd")
    utils.get_tree_selection = orig_gts
    vim.fn.chansend = orig_chansend

    assert.is_true(ok, "ClaudeTreeAdd errored: " .. tostring(err))
    assert.are.equal(1, #opened_harnesses, "tree-add fallback must open a terminal exactly once")
    assert.are.equal("claude", opened_harnesses[1], "tree-add fallback must open the HARNESS's own float")
  end)
end)
