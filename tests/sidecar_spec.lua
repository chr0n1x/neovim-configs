-- sidecar.lua: path derivation, append, and lookup scoring (claude dialect), plus where the
-- sidecar files live. Specs that compute a real sidecar path point stdpath("cache") at a temp
-- dir so nothing lands in the container user's cache.

local utils = require("harness-decorators.utils")
local sidecar = require("harness-decorators.sidecar")

local function read_lines(path)
  local out = {}
  local f = io.open(path, "r")
  if not f then
    return out
  end
  for line in f:lines() do
    out[#out + 1] = line
  end
  f:close()
  return out
end

describe("sidecar", function()
  local tmpdir, orig_stdpath

  before_each(function()
    assert.are.equal("claude", utils.harness, "sidecar spec assumes the claude adapter")
    tmpdir = vim.fn.tempname() .. "-sidecar"
    vim.fn.mkdir(tmpdir, "p")
    orig_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(what)
      if what == "cache" then
        return tmpdir .. "/cache"
      end
      return orig_stdpath(what)
    end
  end)

  after_each(function()
    vim.fn.stdpath = orig_stdpath
    vim.fn.delete(tmpdir, "rf")
  end)

  describe("path", function()
    it("ends with <pid>-<adapter sidecar name>.jsonl", function()
      local p = sidecar.path("abc123")
      assert.is_truthy(p:match("/%d+%-claude%-events%-session%-abc123%.jsonl$"), p)
    end)

    it("path_from_jsonl derives the session id from the JSONL file name", function()
      assert.are.equal(sidecar.path("abc123"), sidecar.path_from_jsonl("/x/y/abc123.jsonl"))
      assert.is_nil(sidecar.path_from_jsonl(nil))
    end)

    it("Given this nvim's pid, Then the path is named by it", function()
      local p = sidecar.path("abc123")
      assert.is_truthy(p:find("/" .. vim.fn.getpid() .. "-claude-events-session-abc123.jsonl", 1, true), p)
    end)

    it("Given two different nvim pids, Then they get two different sidecar paths", function()
      local orig_getpid = vim.fn.getpid
      vim.fn.getpid = function()
        return 111
      end
      local a = sidecar.path("abc123")
      vim.fn.getpid = function()
        return 222
      end
      local b = sidecar.path("abc123")
      vim.fn.getpid = orig_getpid
      assert.are_not.equal(a, b)
    end)

    it("lives under stdpath('cache')/harness/", function()
      local p = sidecar.path("abc123")
      assert.are.equal(tmpdir .. "/cache/harness/", p:sub(1, #tmpdir + #"/cache/harness/"))
    end)
  end)

  describe("append", function()
    it("creates the directory and appends one line per call", function()
      local p = tmpdir .. "/sub/side.jsonl"
      sidecar.append(p, '{"a":1}')
      sidecar.append(p, '{"a":2}')
      assert.are.same({ '{"a":1}', '{"a":2}' }, read_lines(p))
    end)

    it("is a no-op for a nil path", function()
      assert.has_no.errors(function()
        sidecar.append(nil, "x")
      end)
    end)

    it("creates the sidecar directory with mode 0700", function()
      local p = sidecar.path("abc123")
      sidecar.append(p, '{"a":1}')
      local st = assert(vim.uv.fs_stat(tmpdir .. "/cache/harness"))
      assert.are.equal(tonumber("700", 8), bit.band(st.mode, tonumber("777", 8)))
    end)
  end)

  describe("lookup", function()
    local p

    before_each(function()
      p = tmpdir .. "/lookup.jsonl"
      local lines = {
        '{"uuid":"u1","timestamp":5,"toolUseResult":{"content":"c"}}',
        '{"uuid":"u1","timestamp":5,"toolUseResult":{"structuredPatch":[]}}',
        '{"uuid":"u1","timestamp":5,"toolUseResult":{"newString":"n"}}',
        '{"uuid":"u1","timestamp":6,"toolUseResult":{"structuredPatch":[],"tag":"other-ts"}}',
        '{"uuid":"u2","timestamp":5,"toolUseResult":{"structuredPatch":[],"tag":"other-uuid"}}',
        "not json u1 5",
      }
      for _, l in ipairs(lines) do
        sidecar.append(p, l)
      end
    end)

    it("picks the highest-scoring line matching uuid and timestamp", function()
      local ev = sidecar.lookup(p, "u1", 5)
      assert.is_not_nil(ev)
      assert.is_not_nil(ev.toolUseResult.structuredPatch)
      assert.is_nil(ev.toolUseResult.tag)
    end)

    it("filters by id when given", function()
      local ev = sidecar.lookup(p, nil, nil, "other-uuid")
      assert.are.equal("u2", ev.uuid)
    end)

    it("returns nil with no identifiers, a nil path, or a missing file", function()
      assert.is_nil(sidecar.lookup(p, nil, 5, nil))
      assert.is_nil(sidecar.lookup(nil, "u1", 5))
      assert.is_nil(sidecar.lookup(tmpdir .. "/missing.jsonl", "u1", 5))
    end)
  end)
end)
