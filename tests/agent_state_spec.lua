-- Spec for the per-harness agent state adapters (lualine broadcast).
--
-- The pty -> /proc pid resolution (agent-state.pid_for_buf) is Linux-only and needs a live
-- terminal, so it is not exercised here. What IS pinned is the pure logic that turns a pid +
-- cwd into a status and a label: the shared child-process check, and each adapter's parsing of
-- its on-disk session state (claude json, maki cwd_latest + meta title, copilot events.jsonl
-- turn markers, pi session_info name). Adapters read from $HOME, so we point HOME at a temp dir
-- with fixture files and restore it in teardown. sqlite-backed paths (copilot label, crush) have
-- no lsqlite3 in the container, so their degradation path is what's asserted.

local agent_state = require("harness-decorators.agent-state")

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

describe("agent-state: shared child-process check", function()
  it("child_count counts ppid matches in a snapshot", function()
    local snap = "100 1\n200 100\n300 100\n400 999"
    assert.are.equal(2, agent_state.child_count(snap, 100))
    assert.are.equal(0, agent_state.child_count(snap, 500))
    -- pid is matched as a string against the ppid field.
    assert.are.equal(2, agent_state.child_count(snap, "100"))
  end)

  it("child_count returns 0 on nil inputs", function()
    assert.are.equal(0, agent_state.child_count(nil, 100))
    assert.are.equal(0, agent_state.child_count("100 1", nil))
  end)

  it("child_status maps child count to working/idle", function()
    local snap = "200 100"
    assert.are.equal("working", agent_state.child_status(snap, 100))
    assert.are.equal("idle", agent_state.child_status(snap, 999))
  end)

  it("harnesses() returns every adapter that loads (sourced from keymaps discovery)", function()
    local harnesses = agent_state.harnesses()
    -- The candidate list is utils.list_harnesses(); every one of those that ships a state.lua must
    -- appear. This pins the "single source of truth" wiring without hardcoding the roster here.
    local u = require("harness-decorators.utils")
    for _, expected in ipairs(u.list_harnesses()) do
      local has_state = pcall(require, "harness-decorators." .. expected .. ".state")
      if has_state then
        local found = false
        for _, h in ipairs(harnesses) do
          if h.name == expected then
            found = true
            assert.is_boolean(h.installed, "each entry must carry an installed boolean")
            break
          end
        end
        assert.is_true(found, "harnesses() must include " .. expected)
      end
    end
  end)

  it("harnesses() carries an installed boolean consistent with vim.fn.executable", function()
    local harnesses = agent_state.harnesses()
    assert.is_true(#harnesses > 0, "expected at least one harness in the test env")
    for _, h in ipairs(harnesses) do
      assert.is_boolean(h.installed, "installed must be a boolean for " .. h.name)
      -- Cross-check: require the env module and verify the executable check matches.
      local ok_env, cmd = pcall(require, "harness-decorators." .. h.name .. ".env")
      if ok_env and type(cmd) == "string" then
        local exe = cmd:match("^%S+")
        assert.are.equal(vim.fn.executable(exe) == 1, h.installed,
          "installed flag for " .. h.name .. " must match vim.fn.executable(" .. exe .. ")")
      end
    end
  end)
end)

describe("agent-state: per-harness adapters (sandboxed HOME)", function()
  local home
  local orig_home
  local orig_xdg

  setup(function()
    home = vim.fn.tempname() .. "-agentstate"
    vim.fn.mkdir(home, "p")
    orig_home = os.getenv("HOME")
    orig_xdg = os.getenv("XDG_STATE_HOME")
    vim.fn.setenv("HOME", home)
    -- Keep the maki adapter from resolving a real XDG sessions dir that would shadow the fixture.
    if orig_xdg then
      vim.fn.unletenv("XDG_STATE_HOME")
    end
  end)

  teardown(function()
    if orig_home then
      vim.fn.setenv("HOME", orig_home)
    end
    if orig_xdg then
      vim.fn.setenv("XDG_STATE_HOME", orig_xdg)
    else
      vim.cmd("unlet! $XDG_STATE_HOME")
    end
    vim.fn.delete(home, "rf")
  end)

  describe("claude", function()
    local claude
    setup(function()
      claude = require("harness-decorators.claude.state")
    end)

    it("status: busy session file => working", function()
      vim.fn.mkdir(home .. "/.claude/sessions", "p")
      write_file(home .. "/.claude/sessions/1234.json", vim.json.encode({ status = "busy" }))
      assert.are.equal("working", claude.status(1234, "/x"))
    end)

    it("status: non-busy session file => idle", function()
      vim.fn.mkdir(home .. "/.claude/sessions", "p")
      write_file(home .. "/.claude/sessions/1234.json", vim.json.encode({ status = "idle" }))
      assert.are.equal("idle", claude.status(1234, "/x"))
    end)

    it("status: missing session file => unknown (delegate to child check)", function()
      assert.are.equal("unknown", claude.status(9999, "/x"))
    end)

    it("label: user rename wins over ai-title", function()
      vim.fn.mkdir(home .. "/.claude/sessions", "p")
      write_file(
        home .. "/.claude/sessions/1234.json",
        vim.json.encode({ name = "my rename", sessionId = "sid-1" })
      )
      assert.are.equal("my rename", claude.label(1234, "/x"))
    end)

    it("label: falls back to ai-title from the project jsonl", function()
      vim.fn.mkdir(home .. "/.claude/sessions", "p")
      vim.fn.mkdir(home .. "/.claude/projects/-proj", "p")
      write_file(
        home .. "/.claude/sessions/1234.json",
        vim.json.encode({ sessionId = "sid-1" })
      )
      write_file(
        home .. "/.claude/projects/-proj/sid-1.jsonl",
        '{"ai-title":"older"}\n{"aiTitle":"Refactor auth"}\n'
      )
      assert.are.equal("Refactor auth", claude.label(1234, "/x"))
    end)

    it("label: no session file => nil", function()
      assert.is_nil(claude.label(9999, "/x"))
    end)
  end)

  describe("maki", function()
    local maki
    setup(function()
      maki = require("harness-decorators.maki.state")
    end)

    it("status is always unknown (no per-pid signal)", function()
      assert.are.equal("unknown", maki.status(1234, "/x"))
    end)

    it("label: cwd_latest.json + last meta title", function()
      vim.fn.mkdir(home .. "/.maki/sessions", "p")
      write_file(home .. "/.maki/sessions/cwd_latest.json", vim.json.encode({ ["/proj"] = "sess-abc" }))
      write_file(
        home .. "/.maki/sessions/sess-abc.jsonl",
        '{"t":"meta","title":"first title"}\n{"t":"msg"}\n{"t":"meta","title":"Refactoring auth"}\n'
      )
      assert.are.equal("Refactoring auth", maki.label(1234, "/proj"))
    end)

    it("label: unknown cwd => nil", function()
      vim.fn.mkdir(home .. "/.maki/sessions", "p")
      write_file(home .. "/.maki/sessions/cwd_latest.json", vim.json.encode({ ["/other"] = "sess-abc" }))
      assert.is_nil(maki.label(1234, "/proj"))
    end)

    it("label: no sessions dir => nil", function()
      assert.is_nil(maki.label(1234, "/proj"))
    end)

    it("label: a fresh session in a dir with an older one is matched by open time (not cwd_latest)", function()
      -- The regression: cwd_latest.json still points at the PREVIOUS session (it updates lazily), so
      -- a brand-new terminal must be labelled from its own session file, picked out by the open time.
      -- Unique cwd so this test's fixtures don't collide with sibling tests sharing the temp home.
      vim.fn.mkdir(home .. "/.maki/sessions", "p")
      write_file(home .. "/.maki/sessions/cwd_latest.json", vim.json.encode({ ["/proj-match"] = "sess-old" }))
      -- Older session (the one cwd_latest wrongly points at). Header carries the real cwd.
      write_file(
        home .. "/.maki/sessions/sess-old.jsonl",
        '{"t":"header","id":"sess-old","created_at":1000,"cwd":"/proj-match"}\n{"t":"meta","title":"OLD SESSION"}\n'
      )
      -- The fresh session, created ~now (its header created_at matches the terminal's open time).
      local now = os.time()
      write_file(
        home .. "/.maki/sessions/sess-new.jsonl",
        string.format('{"t":"header","id":"sess-new","created_at":%d,"cwd":"/proj-match"}\n', now)
          .. '{"t":"meta","title":"FRESH SESSION"}\n'
      )
      -- Point term.opened_at("maki") at "now" so the matcher picks sess-new, not sess-old.
      local term = require("harness-decorators.term")
      local orig = term.opened_at
      term.opened_at = function(_h)
        return now
      end
      local ok, err = pcall(function()
        assert.are.equal("FRESH SESSION", maki.label(1234, "/proj-match"))
      end)
      term.opened_at = orig
      if not ok then
        error(err)
      end
    end)

    it("label: falls back to cwd_latest when no session matches the open time", function()
      -- Unique cwd + unique session file so this test is isolated from the sibling time-match test.
      vim.fn.mkdir(home .. "/.maki/sessions", "p")
      write_file(home .. "/.maki/sessions/cwd_latest.json", vim.json.encode({ ["/proj-fallback"] = "sess-fb" }))
      -- A session whose created_at is far from the open time: must NOT be matched by time.
      write_file(
        home .. "/.maki/sessions/sess-fb.jsonl",
        '{"t":"header","id":"sess-fb","created_at":1000,"cwd":"/proj-fallback"}\n{"t":"meta","title":"FROM CWD_LATEST"}\n'
      )
      local term = require("harness-decorators.term")
      local orig = term.opened_at
      term.opened_at = function(_h)
        return os.time() -- far from created_at=1000, so the time match fails
      end
      local ok, err = pcall(function()
        assert.are.equal("FROM CWD_LATEST", maki.label(1234, "/proj-fallback"))
      end)
      term.opened_at = orig
      if not ok then
        error(err)
      end
    end)
  end)

  describe("copilot", function()
    local copilot
    setup(function()
      copilot = require("harness-decorators.copilot.state")
    end)

    it("declares no_child_check (helper subprocesses exist at rest)", function()
      assert.is_true(copilot.no_child_check)
    end)

    it("status: trailing turn_start => working", function()
      vim.fn.mkdir(home .. "/.copilot/session-state/sid-12345678", "p")
      write_file(home .. "/.copilot/session-state/sid-12345678/inuse.4321.lock", "")
      write_file(
        home .. "/.copilot/session-state/sid-12345678/events.jsonl",
        '{"event":"assistant.turn_start"}\n{"event":"assistant.turn_end"}\n{"event":"assistant.turn_start"}\n'
      )
      assert.are.equal("working", copilot.status(4321, "/x"))
    end)

    it("status: trailing turn_end => idle", function()
      vim.fn.mkdir(home .. "/.copilot/session-state/sid-12345678", "p")
      write_file(home .. "/.copilot/session-state/sid-12345678/inuse.4321.lock", "")
      write_file(
        home .. "/.copilot/session-state/sid-12345678/events.jsonl",
        '{"event":"assistant.turn_start"}\n{"event":"assistant.turn_end"}\n'
      )
      assert.are.equal("idle", copilot.status(4321, "/x"))
    end)

    it("status: no lock for pid => unknown", function()
      assert.are.equal("unknown", copilot.status(9999, "/x"))
    end)

    it("label: no lsqlite3 in container => 8-char session id fallback", function()
      vim.fn.mkdir(home .. "/.copilot/session-state/sid-12345678", "p")
      write_file(home .. "/.copilot/session-state/sid-12345678/inuse.4321.lock", "")
      -- sid is the session dir basename; without sqlite the label is its first 8 chars.
      assert.are.equal("sid-1234", copilot.label(4321, "/x"))
    end)

    it("label: no lock for pid => nil", function()
      assert.is_nil(copilot.label(9999, "/x"))
    end)
  end)

  describe("crush", function()
    local crush
    setup(function()
      crush = require("harness-decorators.crush.state")
    end)

    it("status: no project db => unknown (delegate to child check)", function()
      assert.are.equal("unknown", crush.status(1234, "/no-such-dir"))
    end)

    it("label: no project db => nil", function()
      assert.is_nil(crush.label(1234, "/no-such-dir"))
    end)
  end)

  describe("pi", function()
    local pi
    setup(function()
      pi = require("harness-decorators.pi.state")
    end)

    it("status is always unknown (rides the child check)", function()
      assert.are.equal("unknown", pi.status(1234, "/x"))
    end)

    it("label: session_info.name wins over first user message", function()
      local dir = home .. "/.pi/agent/sessions/--proj--"
      vim.fn.mkdir(dir, "p")
      write_file(
        dir .. "/s.jsonl",
        '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello world"}]}}\n'
          .. '{"type":"session_info","name":"Refactor auth"}\n'
      )
      assert.are.equal("Refactor auth", pi.label(1234, "/proj"))
    end)

    it("label: falls back to first user message when no session_info", function()
      local dir = home .. "/.pi/agent/sessions/--proj--"
      vim.fn.mkdir(dir, "p")
      write_file(
        dir .. "/s.jsonl",
        '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hello world"}]}}\n'
      )
      assert.are.equal("hello world", pi.label(1234, "/proj"))
    end)

    it("label: no session dir for cwd => nil", function()
      assert.is_nil(pi.label(1234, "/no-such-dir"))
    end)

    it("label: a fresh session in a dir with an older one is matched by open time (not newest mtime)", function()
      -- The regression: the previous session's file has the NEWEST mtime (it was touched last), so a
      -- brand-new terminal must be labelled from its own file, picked out by the open time.
      local dir = home .. "/.pi/agent/sessions/--proj--"
      vim.fn.mkdir(dir, "p")
      local now = os.time()
      write_file(
        dir .. "/fresh.jsonl",
        '{"type":"session_info","name":"FRESH PI"}\n'
      )
      write_file(
        dir .. "/old.jsonl",
        '{"type":"session_info","name":"OLD PI"}\n'
      )
      -- Make the OLD file the most recently modified (the trap "newest mtime" would fall into).
      vim.uv.fs_utime(dir .. "/old.jsonl", now + 500, now + 500)
      vim.uv.fs_utime(dir .. "/fresh.jsonl", now, now)
      local term = require("harness-decorators.term")
      local orig = term.opened_at
      term.opened_at = function(_h)
        return now
      end
      local ok, err = pcall(function()
        assert.are.equal("FRESH PI", pi.label(1234, "/proj"))
      end)
      term.opened_at = orig
      if not ok then
        error(err)
      end
    end)
  end)

  describe("term.opened_at", function()
    it("returns nil when the harness has no live instance", function()
      local term = require("harness-decorators.term")
      term._reset()
      assert.is_nil(term.opened_at("claude"))
    end)

    it("records the open time on a fresh open and exposes it while live", function()
      local snacks = require("snacks.terminal")
      local orig_open = snacks.open
      snacks.open = function(_cmd, _opts)
        return {
          buf = vim.api.nvim_create_buf(false, true),
          win = nil,
          hide = function() end,
          show = function() end,
          focus = function() end,
          close = function() end,
          buf_valid = function(self)
            return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
          end,
        }
      end
      local term = require("harness-decorators.term")
      term._reset()
      local before = os.time()
      term.open("maki")
      local t = term.opened_at("maki")
      assert.is_not_nil(t, "opened_at must be set after a fresh open")
      assert.is_true(t >= before and t <= os.time(), "open time must be ~now")
      snacks.open = orig_open
      term._reset()
    end)
  end)
end)
