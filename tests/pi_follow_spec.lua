-- pi edit-following + session-state bridge (pi/follow.lua + pi/state.lua). Covers the testable
-- halves of the bridge: diff parsing, the ingest() dispatch (edit -> HarnessEdit, session ->
-- registry), staleness, the symlink bootstrap, and state.lua preferring pushed state over the
-- filename fallback. The extension .ts (thin field-extraction + execFile) is not unit-tested here.

local follow = require("harness-decorators.pi.follow")

local function b64(tbl)
  return vim.base64.encode(vim.json.encode(tbl))
end

describe("pi follow bridge", function()
  before_each(function()
    follow._reset()
  end)

  describe("starting_line_from_diff", function()
    it("returns the first changed line number (pi '+NNN' format)", function()
      assert.are.equal(163, follow.starting_line_from_diff(" 161   }\n 162 \n+163   // new\n 164   x"))
    end)

    it("recognizes a deletion sign too", function()
      assert.are.equal(165, follow.starting_line_from_diff(" 164   a\n-165   gone\n 166   b"))
    end)

    it("returns nil when no line changed, or on non-string input", function()
      assert.is_nil(follow.starting_line_from_diff(" 1   a\n 2   b"))
      assert.is_nil(follow.starting_line_from_diff(nil))
    end)
  end)

  describe("short_uuid", function()
    it("returns the first 8 chars", function()
      assert.are.equal("01a0a1c2", follow.short_uuid("01a0a1c2-5d71-72af-bafe-f08b1ecb862f"))
    end)
    it("returns nil for empty/nil", function()
      assert.is_nil(follow.short_uuid(nil))
      assert.is_nil(follow.short_uuid(""))
    end)
  end)

  describe("ingest -> edit", function()
    local group

    before_each(function()
      group = vim.api.nvim_create_augroup("PiFollowEditSpec", { clear = true })
    end)
    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end)

    local function capture()
      local got
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "HarnessEdit",
        callback = function(args)
          got = args.data
        end,
      })
      return function()
        return got
      end
    end

    it("fires User HarnessEdit with the decoded path and parsed starting line", function()
      local get = capture()
      follow.ingest(b64({ kind = "edit", file_path = "/tmp/x.lua", operation = "Edit", diff = " 9   a\n+10   b" }))
      vim.wait(500, function()
        return get() ~= nil
      end)
      local data = get()
      assert.is_not_nil(data)
      assert.are.equal("/tmp/x.lua", data.file_path)
      assert.are.equal("Edit", data.operation)
      assert.are.equal(10, data.starting_line)
    end)

    it("fails soft on garbage base64, non-table JSON, unknown kind, or missing file_path", function()
      local get = capture()
      assert.has_no.errors(function()
        follow.ingest("!!! not base64 !!!")
      end)
      assert.has_no.errors(function()
        follow.ingest(vim.base64.encode("[1,2,3]"))
      end)
      assert.has_no.errors(function()
        follow.ingest(b64({ kind = "nonsense" }))
      end)
      assert.has_no.errors(function()
        follow.ingest(b64({ kind = "edit", operation = "Edit" }))
      end)
      vim.wait(100)
      assert.is_nil(get(), "no HarnessEdit should fire for malformed input")
    end)
  end)

  describe("ingest -> session (registry)", function()
    it("records status + session_id, indexed by cwd", function()
      follow.ingest(b64({
        kind = "session",
        phase = "status",
        session_id = "01a0a1c2-aaaa",
        cwd = "/repo/a",
        session_file = "/s/a.jsonl",
        status = "working",
      }))
      local s = follow.session_for_cwd("/repo/a")
      assert.is_not_nil(s)
      assert.are.equal("01a0a1c2-aaaa", s.session_id)
      assert.are.equal("working", s.status)
      assert.are.equal("/s/a.jsonl", s.session_file)
    end)

    it("latest session for a cwd wins the index", function()
      follow.ingest(b64({ kind = "session", session_id = "old", cwd = "/repo/b", status = "idle" }))
      follow.ingest(b64({ kind = "session", session_id = "new", cwd = "/repo/b", status = "working" }))
      assert.are.equal("new", follow.session_for_cwd("/repo/b").session_id)
    end)

    it("shutdown drops the session", function()
      follow.ingest(b64({ kind = "session", session_id = "sid", cwd = "/repo/c", status = "idle" }))
      assert.is_not_nil(follow.session_for_cwd("/repo/c"))
      follow.ingest(b64({ kind = "session", phase = "shutdown", session_id = "sid", cwd = "/repo/c" }))
      assert.is_nil(follow.session_for_cwd("/repo/c"))
    end)

    it("treats a stale entry as gone (crashed pi does not stay 'working')", function()
      follow.ingest(b64({ kind = "session", session_id = "sid", cwd = "/repo/d", status = "working" }))
      -- fresh: present; far-future 'now': stale -> nil
      assert.is_not_nil(follow.session_for_cwd("/repo/d", os.time()))
      assert.is_nil(follow.session_for_cwd("/repo/d", os.time() + 3600))
    end)

    it("returns nil for an unknown cwd / bad input", function()
      assert.is_nil(follow.session_for_cwd("/nope"))
      assert.is_nil(follow.session_for_cwd(nil))
    end)
  end)

  describe("ensure (symlink bootstrap)", function()
    local tmp

    before_each(function()
      tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
    end)
    after_each(function()
      vim.fn.delete(tmp, "rf")
    end)

    it("creates the symlink when the target is absent (incl. missing parent dir)", function()
      local src = tmp .. "/src.ts"
      vim.fn.writefile({ "// ext" }, src)
      local tgt = tmp .. "/extdir/nvim-harness-follow.ts"

      assert.are.equal("linked", follow.ensure({ source = src, target = tgt }))
      local st = vim.uv.fs_lstat(tgt)
      assert.are.equal("link", st and st.type)
      assert.are.equal(vim.uv.fs_realpath(src), vim.uv.fs_realpath(tgt))
    end)

    it("is idempotent when the link already points at the source", function()
      local src = tmp .. "/src.ts"
      vim.fn.writefile({ "x" }, src)
      local tgt = tmp .. "/e/nvim-harness-follow.ts"
      assert.are.equal("linked", follow.ensure({ source = src, target = tgt }))
      assert.are.equal("exists", follow.ensure({ source = src, target = tgt }))
    end)

    it("repoints a stale symlink at the correct source", function()
      local src = tmp .. "/src.ts"
      vim.fn.writefile({ "x" }, src)
      local other = tmp .. "/other.ts"
      vim.fn.writefile({ "y" }, other)
      local tgt = tmp .. "/e/nvim-harness-follow.ts"
      vim.fn.mkdir(tmp .. "/e", "p")
      vim.uv.fs_symlink(other, tgt)

      assert.are.equal("updated", follow.ensure({ source = src, target = tgt }))
      assert.are.equal(vim.uv.fs_realpath(src), vim.uv.fs_realpath(tgt))
    end)

    it("refuses to clobber a real file at the target", function()
      local src = tmp .. "/src.ts"
      vim.fn.writefile({ "x" }, src)
      local tgt = tmp .. "/real.ts"
      vim.fn.writefile({ "keep" }, tgt)

      assert.are.equal("skipped", follow.ensure({ source = src, target = tgt }))
      assert.are.same({ "keep" }, vim.fn.readfile(tgt))
    end)
  end)

  describe("state.lua consumes pushed state", function()
    local state = require("harness-decorators.pi.state")

    it("status prefers the pushed working/idle status", function()
      follow.ingest(b64({ kind = "session", session_id = "s1", cwd = "/repo/live", status = "working" }))
      assert.are.equal("working", state.status(nil, "/repo/live"))
    end)

    it("status is 'unknown' when nothing was pushed", function()
      assert.are.equal("unknown", state.status(nil, "/repo/nothing-pushed"))
    end)

    it("label prefers the pushed short uuid", function()
      follow.ingest(b64({
        kind = "session",
        session_id = "01a0a1c2-5d71-72af-bafe-f08b1ecb862f",
        cwd = "/repo/labeled",
        status = "idle",
      }))
      assert.are.equal("01a0a1c2", state.label(nil, "/repo/labeled"))
    end)

    it("label falls back to the uuid parsed from the session filename when nothing pushed", function()
      local home = vim.fn.tempname()
      local cwd = "/proj/x"
      -- dir_name("/proj/x") = "--proj-x--"
      local dir = home .. "/.pi/agent/sessions/--proj-x--"
      vim.fn.mkdir(dir, "p")
      local uuid = "deadbeef-1111-2222-3333-444455556666"
      vim.fn.writefile({ "{}" }, dir .. "/2026-01-01T00-00-00-000Z_" .. uuid .. ".jsonl")

      local orig = vim.fn.getenv("HOME")
      vim.fn.setenv("HOME", home)
      local label = state.label(nil, cwd)
      vim.fn.setenv("HOME", orig == vim.NIL and "" or orig)
      vim.fn.delete(home, "rf")

      assert.are.equal("deadbeef", label)
    end)
  end)

  describe("adapter wiring", function()
    it("declares push-based following so the JSONL watcher stays quiet", function()
      assert.is_true(require("harness-decorators.pi").push_following)
    end)

    it("extracts the session id and renders pushed diffs for history", function()
      local pi = require("harness-decorators.pi")
      local id = "01a0a1c2-2350-76fa-9de0-430fb6578058"
      assert.are.equal(id, pi.session_id("/tmp/2026-01-01T00-00-00-000Z_" .. id .. ".jsonl"))
      assert.are.equal(3, pi.score_event({ type = "pi_harness_edit", diff = "+ 3 changed" }))
      assert.are.equal("+ 3 changed", pi.extract_diff({ diff = "+ 3 changed" }))
      assert.are.equal("(no diff data available)", pi.extract_diff(nil))
    end)

    it("adds pi's edit history to the shared <leader>cu picker", function()
      local found
      for _, spec in ipairs(require("harness-decorators.pi.keymaps")) do
        if spec[1] == "<leader>cu" then
          found = spec
          break
        end
      end
      assert.is_not_nil(found)
      assert.are.equal("n", found.mode[1])
    end)

    it("the pi adapter exposes on_activate", function()
      assert.are.equal("function", type(require("harness-decorators.pi").on_activate))
    end)

    it("switching to pi runs the activation hook (symlink ensure)", function()
      local pi = require("harness-decorators.pi")
      local original = pi.on_activate
      local called = false
      pi.on_activate = function()
        called = true
      end

      local switch = require("harness-decorators.switch")
      local start = switch.current()
      if start == "pi" then
        switch.switch("claude")
      end
      switch.switch("pi")

      pi.on_activate = original
      if start then
        pcall(switch.switch, start)
      end

      assert.is_true(called, "switch.switch('pi') should invoke pi.on_activate")
    end)
  end)
end)
