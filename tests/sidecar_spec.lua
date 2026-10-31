-- sidecar.lua: path derivation, append, and lookup scoring (claude dialect), plus where the
-- sidecar files live. Specs that compute a real sidecar path point stdpath("cache") at a temp
-- dir so nothing lands in the container user's cache.

local active = require("harness-decorators.active")
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
    assert.are.equal("claude", active.get(), "sidecar spec assumes the claude adapter")
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

    it("Given the directory cannot be created, Then append returns without raising and writes nothing", function()
      local p = sidecar.path("abc123")
      local orig_mkdir = vim.fn.mkdir
      vim.fn.mkdir = function()
        error("E739: Cannot create directory")
      end
      local ok, err = pcall(sidecar.append, p, '{"a":1}')
      vim.fn.mkdir = orig_mkdir
      assert.is_true(ok, tostring(err))
      assert.is_nil(vim.uv.fs_stat(p))
    end)

    it("creates the sidecar directory with mode 0700", function()
      local p = sidecar.path("abc123")
      sidecar.append(p, '{"a":1}')
      local st = assert(vim.uv.fs_stat(tmpdir .. "/cache/harness"))
      assert.are.equal(tonumber("700", 8), bit.band(st.mode, tonumber("777", 8)))
    end)
  end)

  describe("exit cleanup", function()
    local orig_mod

    local function cleanup_autocmds()
      local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "HarnessSidecarCleanup", event = "VimLeave" })
      return ok and cmds or {}
    end

    before_each(function()
      orig_mod = package.loaded["harness-decorators.sidecar"]
      pcall(vim.api.nvim_del_augroup_by_name, "HarnessSidecarCleanup")
      package.loaded["harness-decorators.sidecar"] = nil
    end)

    after_each(function()
      package.loaded["harness-decorators.sidecar"] = orig_mod
    end)

    it("Given sidecar is only required, Then no exit cleanup autocmd is registered", function()
      require("harness-decorators.sidecar")
      assert.are.equal(0, #cleanup_autocmds())
    end)

    it(
      "Given this nvim writes a sidecar, Then exactly one exit cleanup autocmd exists and firing it removes only this pid's sidecars",
      function()
        local fresh = require("harness-decorators.sidecar")
        local own = fresh.path("abc123")
        fresh.append(own, '{"a":1}')
        fresh.append(own, '{"a":2}')
        local other = fresh.dir() .. "/" .. (vim.fn.getpid() + 1) .. "-claude-events-session-abc123.jsonl"
        local f = assert(io.open(other, "w"))
        f:close()

        assert.are.equal(1, #cleanup_autocmds())
        vim.api.nvim_exec_autocmds("VimLeave", { group = "HarnessSidecarCleanup" })
        assert.is_nil(vim.uv.fs_stat(own), "this nvim's sidecar is removed")
        assert.is_not_nil(vim.uv.fs_stat(other), "another pid's sidecar is kept")
      end
    )

    it(
      "Given a producer appends while the VimLeavePre handlers run, When nvim exits, Then no sidecar with this pid remains",
      function()
        local fresh = require("harness-decorators.sidecar")
        local own = fresh.path("abc123")
        fresh.append(own, '{"a":1}')
        local late = vim.api.nvim_create_augroup("SidecarLateProducerSpec", { clear = true })
        vim.api.nvim_create_autocmd("VimLeavePre", {
          group = late,
          callback = function()
            fresh.append(own, '{"a":2}')
          end,
        })

        pcall(vim.api.nvim_exec_autocmds, "VimLeavePre", { group = "HarnessSidecarCleanup" })
        vim.api.nvim_exec_autocmds("VimLeavePre", { group = late })
        pcall(vim.api.nvim_exec_autocmds, "VimLeave", { group = "HarnessSidecarCleanup" })
        vim.api.nvim_del_augroup_by_id(late)

        assert.are.same({}, vim.fn.glob(fresh.dir() .. "/" .. vim.fn.getpid() .. "-*.jsonl", true, true))
      end
    )
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
