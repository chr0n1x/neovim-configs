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

  it("resolves a macOS terminal process from its pty", function()
    local snap = "46253 46241 ??\n47496 46253 ttys006\n49254 47496 ttys006"
    assert.are.equal(47496, agent_state.pid_from_tty_snapshot(snap, "/dev/ttys006"))
  end)

  it("resolves a Linux terminal process from its pty", function()
    local snap = "100 1 ?\n200 100 pts/3\n300 200 pts/3"
    assert.are.equal(200, agent_state.pid_from_tty_snapshot(snap, "/dev/pts/3"))
  end)

  it("returns nil when no process owns the terminal pty", function()
    assert.is_nil(agent_state.pid_from_tty_snapshot("100 1 ??", "/dev/ttys006"))
  end)

  it("Given a terminal buffer, When its pid is resolved, Then it is the job pid and no ps runs", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local job
    vim.api.nvim_buf_call(buf, function()
      job = vim.fn.jobstart({ "sleep", "30" }, { term = true })
    end)
    local real_popen, real_system = io.popen, vim.system
    local spawned = 0
    io.popen = function(...)
      spawned = spawned + 1
      return real_popen(...)
    end
    vim.system = function(...)
      spawned = spawned + 1
      return real_system(...)
    end
    local ok, pid = pcall(agent_state.pid_for_buf, buf)
    io.popen, vim.system = real_popen, real_system
    local want = vim.fn.jobpid(job)
    vim.fn.jobstop(job)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(ok, pid)
    assert.are.equal(want, pid)
    assert.are.equal(0, spawned, "pid lookup must not spawn ps")
  end)

  it("Given jobpid fails and ps lists nothing, When its pid is resolved, Then the /proc scan finds the job", function()
    if vim.fn.isdirectory("/proc/self") == 0 then
      return pending("needs Linux /proc")
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local job
    vim.api.nvim_buf_call(buf, function()
      job = vim.fn.jobstart({ "sleep", "30" }, { term = true })
    end)
    local want = vim.fn.jobpid(job)
    local real_popen, real_jobpid = io.popen, vim.fn.jobpid
    vim.fn.jobpid = function()
      error("no job")
    end
    io.popen = function(cmd, ...)
      if cmd == "ps -eo pid=,ppid=,tty=" then
        return real_popen("true")
      end
      return real_popen(cmd, ...)
    end
    local ok, pid = pcall(agent_state.pid_for_buf, buf)
    io.popen, vim.fn.jobpid = real_popen, real_jobpid
    vim.fn.jobstop(job)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(ok, pid)
    assert.are.equal(want, pid)
  end)

  it("Given all_async, When it is called, Then it returns before polling and the callback gets the results", function()
    local got
    agent_state.all_async(function(all)
      got = all
    end)
    assert.is_nil(got, "the callback must not run on the calling stack")
    assert.is_true(vim.wait(5000, function()
      return got ~= nil
    end, 10))
    assert.are.equal("table", type(got))
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
        assert.are.equal(
          vim.fn.executable(exe) == 1,
          h.installed,
          "installed flag for " .. h.name .. " must match vim.fn.executable(" .. exe .. ")"
        )
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
      write_file(home .. "/.claude/sessions/1234.json", vim.json.encode({ name = "my rename", sessionId = "sid-1" }))
      assert.are.equal("my rename", claude.label(1234, "/x"))
    end)

    it("label: falls back to ai-title from the project jsonl", function()
      vim.fn.mkdir(home .. "/.claude/sessions", "p")
      vim.fn.mkdir(home .. "/.claude/projects/-proj", "p")
      write_file(home .. "/.claude/sessions/1234.json", vim.json.encode({ sessionId = "sid-1" }))
      write_file(home .. "/.claude/projects/-proj/sid-1.jsonl", '{"ai-title":"older"}\n{"aiTitle":"Refactor auth"}\n')
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

    it("session id uses the last completed sqlite3 CLI result when lsqlite3 is unavailable", function()
      vim.fn.mkdir(home .. "/project/.crush", "p")
      local db_path = home .. "/project/.crush/crush.db"
      write_file(db_path, "fixture")
      local utils = require("harness-decorators.utils")
      local original_executable = utils.command_executable
      local original_system = vim.system
      utils.command_executable = function()
        return true
      end
      local callback
      vim.system = function(_, _, cb)
        callback = cb
      end
      crush._reset()
      local initial = crush.session_id(1234, home .. "/project")
      callback({ code = 0, stdout = "d5bb8c50-400e-4b7b\n" })
      local updated = crush.session_id(1234, home .. "/project")
      utils.command_executable = original_executable
      vim.system = original_system
      crush._reset()
      assert.is_nil(initial)
      assert.are.equal("d5bb8c50-400e-4b7b", updated)
    end)

    it("notifies once when no SQLite reader is available", function()
      vim.fn.mkdir(home .. "/project/.crush", "p")
      write_file(home .. "/project/.crush/crush.db", "fixture")
      local utils = require("harness-decorators.utils")
      local original_executable = utils.command_executable
      local original_notify = vim.notify
      local notes = {}
      utils.command_executable = function()
        return false
      end
      vim.notify = function(message)
        notes[#notes + 1] = message
      end
      crush._reset()
      crush.session_id(1234, home .. "/project")
      crush.session_id(1234, home .. "/project")
      utils.command_executable = original_executable
      vim.notify = original_notify
      assert.are.equal(1, #notes)
      assert.is_not_nil(notes[1]:find("sqlite3", 1, true))
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

    it("Given pushed pi state, When status and label are read, Then the pushed status and short id win", function()
      local module = "harness-decorators.pi.follow"
      local original = package.loaded[module]
      local session = { status = "working", session_id = "abcdef12-3456" }
      package.loaded[module] = {
        session_for_cwd = function()
          return session
        end,
        short_uuid = function(id)
          return id:sub(1, 8)
        end,
      }
      local ok, err = pcall(function()
        assert.are.equal("working", pi.status(1234, "/pushed"))
        assert.are.equal("abcdef12", pi.label(1234, "/pushed"))
        session.status = "idle"
        assert.are.equal("idle", pi.status(1234, "/pushed"))
      end)
      package.loaded[module] = original
      assert(ok, err)
    end)

    it("label: returns the short (8-char) uuid parsed from the session filename", function()
      -- No pushed session state here, so label uses the filename fallback (…_<uuid>.jsonl).
      require("harness-decorators.pi.follow")._reset()
      local dir = home .. "/.pi/agent/sessions/--proj--"
      vim.fn.mkdir(dir, "p")
      write_file(dir .. "/2026-01-01T00-00-00-000Z_01a0a1c2-5d71-72af-bafe-f08b1ecb862f.jsonl", "{}\n")
      assert.are.equal("01a0a1c2", pi.label(1234, "/proj"))
    end)

    it("label: no session dir for cwd => nil", function()
      require("harness-decorators.pi.follow")._reset()
      assert.is_nil(pi.label(1234, "/no-such-dir"))
    end)

    it("label: a fresh session in a dir with an older one is matched by open time (not newest mtime)", function()
      -- The regression: the previous session's file has the NEWEST mtime (it was touched last), so a
      -- brand-new terminal must be labelled from its own file, picked out by the open time.
      require("harness-decorators.pi.follow")._reset()
      -- Unique cwd + unique session dir: the sibling label spec leaves a 01a0a1c2 file in --proj--,
      -- and a shared dir would let its mtime tie with this test's fresh file (dt=0), so the
      -- open-time matcher breaks the tie by readdir order and picks the wrong file. A fresh dir
      -- contains ONLY this test's two files, which is what the regression is about.
      local cwd = "/proj-fresh"
      local dir = home .. "/.pi/agent/sessions/--proj-fresh--"
      vim.fn.mkdir(dir, "p")
      local now = os.time()
      local fresh = dir .. "/2026-01-01T00-00-00-000Z_aaaaaaaa-1111-2222-3333-444444444444.jsonl"
      local old = dir .. "/2025-01-01T00-00-00-000Z_bbbbbbbb-1111-2222-3333-444444444444.jsonl"
      write_file(fresh, "{}\n")
      write_file(old, "{}\n")
      -- Make the OLD file the most recently modified (the trap "newest mtime" would fall into).
      vim.uv.fs_utime(old, now + 500, now + 500)
      vim.uv.fs_utime(fresh, now, now)
      local term = require("harness-decorators.term")
      -- Reset the shared per-harness state table first: a live instance left by an earlier spec
      -- (term/park/switch/picker stub snacks.open and open fakes) would make the real term.opened_at
      -- return a different timestamp than `now`. We stub opened_at to `now` anyway (the point of the
      -- test is the matcher, not the clock) - the reset just guarantees no stray live instance can
      -- shadow the stub or leak into pi.label's fallback.
      term._reset()
      local orig = term.opened_at
      term.opened_at = function(_h)
        return now
      end
      local ok, err = pcall(function()
        assert.are.equal("aaaaaaaa", pi.label(1234, cwd))
      end)
      term.opened_at = orig
      term._reset()
      if not ok then
        error(err)
      end
    end)
  end)

  describe("pig", function()
    local pig
    setup(function()
      pig = require("harness-decorators.pig.state")
    end)

    it(
      "Given pig has no session for the cwd, When status is polled, Then it is unknown (no child check: pig keeps a node child)",
      function()
        assert.are.equal("unknown", pig.status(1234, "/x"))
        assert.is_true(pig.no_child_check, "pig's always-alive node child would read as working")
      end
    )

    it("Given pig's last message is an assistant that stopped, When status is polled, Then it is idle", function()
      local dir = home .. "/.pig/agent/sessions/--pig-turn--"
      vim.fn.mkdir(dir, "p")
      local f = dir .. "/2026-01-01T00-00-00-000Z_aaaa0000-5d71-72af-bafe-f08b1ecb862f.jsonl"
      write_file(
        f,
        '{"type":"message","message":{"role":"user"}}\n{"type":"message","message":{"role":"assistant","stopReason":"aborted"}}\n'
      )
      assert.are.equal("idle", pig.status(1234, "/pig-turn"))
      write_file(f, '{"type":"message","message":{"role":"assistant","stopReason":"toolUse"}}\n')
      assert.are.equal("working", pig.status(1234, "/pig-turn"))
      write_file(
        f,
        '{"type":"message","message":{"role":"assistant","stopReason":"stop"}}\n{"type":"message","message":{"role":"user"}}\n'
      )
      assert.are.equal("working", pig.status(1234, "/pig-turn"))
    end)

    it("Given a session under ~/.pig, When label is read, Then it is the short uuid from that file", function()
      local dir = home .. "/.pig/agent/sessions/--pig-proj--"
      vim.fn.mkdir(dir, "p")
      write_file(dir .. "/2026-01-01T00-00-00-000Z_c0ffee00-5d71-72af-bafe-f08b1ecb862f.jsonl", "{}\n")
      assert.are.equal("c0ffee00", pig.label(1234, "/pig-proj"))
    end)

    it("Given a session only under ~/.pi, When pig label is read, Then it is nil (pig never reads ~/.pi)", function()
      local dir = home .. "/.pi/agent/sessions/--pi-only--"
      vim.fn.mkdir(dir, "p")
      write_file(dir .. "/2026-01-01T00-00-00-000Z_deadbeef-5d71-72af-bafe-f08b1ecb862f.jsonl", "{}\n")
      assert.is_nil(pig.label(1234, "/pi-only"))
    end)

    it("Given a session only under ~/.pig, When pi label is read, Then it is nil (pi never reads ~/.pig)", function()
      require("harness-decorators.pi.follow")._reset()
      local dir = home .. "/.pig/agent/sessions/--pig-only--"
      vim.fn.mkdir(dir, "p")
      write_file(dir .. "/2026-01-01T00-00-00-000Z_feedface-5d71-72af-bafe-f08b1ecb862f.jsonl", "{}\n")
      assert.is_nil(require("harness-decorators.pi.state").label(1234, "/pig-only"))
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
