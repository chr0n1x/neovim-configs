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
