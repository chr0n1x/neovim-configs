-- Watcher input parsing: the shared JSONL path filter, the inotifywait and fswatch log line
-- formats, the poll that reads the watcher log, and the orphan reaper. The parsers and the
-- poll are module locals exposed as watcher._name; the poll is driven through a temp log
-- file with process_jsonl_write stubbed to capture the paths it is handed.

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

describe("watcher input parsing", function()
  describe("filter_jsonl_path", function()
    it("keeps a root session .jsonl", function()
      assert.are.equal("/p/h/s.jsonl", watcher._filter_jsonl_path("/p/h/s.jsonl"))
    end)

    it("skips non-jsonl, subagent and archive paths", function()
      assert.is_nil(watcher._filter_jsonl_path("/p/h/s.txt"))
      assert.is_nil(watcher._filter_jsonl_path("/p/h/s/subagents/a.jsonl"))
      assert.is_nil(watcher._filter_jsonl_path("/p/sessions/archive/id/1.jsonl"))
    end)
  end)

  describe("inotifywait line", function()
    it("joins '<dir> <events> <file>' into one path", function()
      assert.are.equal("/p/h/s.jsonl", watcher._parse_watcher_line("/p/h/ CLOSE_WRITE,CLOSE s.jsonl"))
    end)

    it("keeps spaces in the file name", function()
      assert.are.equal("/p/h/my s.jsonl", watcher._parse_watcher_line("/p/h/ MODIFY my s.jsonl"))
    end)

    it("ignores empty, malformed and filtered lines", function()
      assert.is_nil(watcher._parse_watcher_line(""))
      assert.is_nil(watcher._parse_watcher_line("garbage"))
      assert.is_nil(watcher._parse_watcher_line("/p/h/ MODIFY s.txt"))
      assert.is_nil(watcher._parse_watcher_line("/p/h/subagents/ MODIFY a.jsonl"))
    end)
  end)

  describe("fswatch line", function()
    it("takes the bare path, trimming surrounding whitespace", function()
      assert.are.equal("/p/h/s.jsonl", watcher._parse_fswatch_line("/p/h/s.jsonl"))
      assert.are.equal("/p/h/s.jsonl", watcher._parse_fswatch_line("  /p/h/s.jsonl  "))
    end)

    it("ignores empty and filtered lines", function()
      assert.is_nil(watcher._parse_fswatch_line(""))
      assert.is_nil(watcher._parse_fswatch_line("/p/h/s.txt"))
      assert.is_nil(watcher._parse_fswatch_line("/p/sessions/archive/id/1.jsonl"))
    end)
  end)

  describe("process_watcher_log", function()
    local tmpdir, log, got, logs
    local orig = {}

    before_each(function()
      tmpdir = vim.fn.tempname() .. "-wlog"
      vim.fn.mkdir(tmpdir, "p")
      log = tmpdir .. "/w.log"
      orig.write = watcher.process_jsonl_write
      orig.log_path = watcher.watcher_log
      orig.backend = watcher.watcher_backend
      orig.pos = watcher.watcher_last_pos
      orig.ulog = utils.log
      got, logs = {}, {}
      watcher.process_jsonl_write = function(p)
        got[#got + 1] = p
      end
      utils.log = function(msg, level)
        logs[#logs + 1] = { msg = msg, level = level }
      end
      watcher.watcher_log = log
      watcher.watcher_last_pos = 0
    end)

    after_each(function()
      watcher.process_jsonl_write = orig.write
      watcher.watcher_log = orig.log_path
      watcher.watcher_backend = orig.backend
      watcher.watcher_last_pos = orig.pos
      utils.log = orig.ulog
      vim.fn.delete(tmpdir, "rf")
    end)

    it("reads fswatch lines when the backend is fswatch", function()
      watcher.watcher_backend = "fswatch"
      write_file(log, "/p/h/a.jsonl\n/p/h/a.txt\n/p/h/subagents/x.jsonl\n/p/h/b.jsonl\n")
      watcher._process_watcher_log()
      assert.are.same({ "/p/h/a.jsonl", "/p/h/b.jsonl" }, got)
    end)

    it("reads inotifywait lines otherwise, and only the new part on the next poll", function()
      watcher.watcher_backend = "inotifywait"
      write_file(log, "/p/h/ MODIFY a.jsonl\n")
      watcher._process_watcher_log()
      local f = assert(io.open(log, "a"))
      f:write("/p/h/ CLOSE_WRITE,CLOSE b.jsonl\n")
      f:close()
      watcher._process_watcher_log()
      assert.are.same({ "/p/h/a.jsonl", "/p/h/b.jsonl" }, got)
    end)

    it("Given processing a logged path throws, Then the error is logged at ERROR", function()
      watcher.watcher_backend = "fswatch"
      watcher.process_jsonl_write = function()
        error("dispatch blew up")
      end
      write_file(log, "/p/h/a.jsonl\n")
      watcher._process_watcher_log()
      local found = false
      for _, l in ipairs(logs) do
        if l.level == vim.log.levels.ERROR and tostring(l.msg):find("dispatch blew up", 1, true) then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it(
      "Given the log grew by more than 64KB twice by different amounts, Then each poll skips to the end with the same WARN text and the byte count at DEBUG",
      function()
        watcher.watcher_backend = "fswatch"
        write_file(log, string.rep("/p/h/a.jsonl\n", 6000))
        watcher._process_watcher_log()
        local f = assert(io.open(log, "a"))
        f:write(string.rep("/p/h/b.jsonl\n", 7000))
        f:close()
        watcher._process_watcher_log()
        assert.are.same({}, got)
        assert.are.equal(vim.uv.fs_stat(log).size, watcher.watcher_last_pos)

        local warns, debug_text = {}, ""
        for _, l in ipairs(logs) do
          local msg = tostring(l.msg)
          if l.level == vim.log.levels.WARN and msg:find("skipped", 1, true) then
            warns[#warns + 1] = msg
          elseif l.level == vim.log.levels.DEBUG then
            debug_text = debug_text .. msg .. "\n"
          end
        end
        assert.are.equal(2, #warns, "one WARN per skip")
        assert.are.equal(warns[1], warns[2], "the WARN text is the same for both skips")
        assert.is_nil(warns[1]:find("78000", 1, true), "the WARN text carries no byte count")
        assert.is_truthy(debug_text:find("78000", 1, true), "the first skip's byte count is logged at DEBUG")
        assert.is_truthy(debug_text:find("91000", 1, true), "the second skip's byte count is logged at DEBUG")
      end
    )
  end)

  describe("reap_dead_watchers", function()
    local tmpdir, dir, orig_stdpath, procs

    local function sleeper()
      local handle, pid = vim.uv.spawn("sleep", { args = { "60" } }, function() end)
      procs[#procs + 1] = { handle = handle, pid = pid }
      return pid
    end

    local function dead_pid()
      local done = false
      local handle, pid = vim.uv.spawn("true", {}, function()
        done = true
      end)
      vim.wait(2000, function()
        return done
      end)
      handle:close()
      return pid
    end

    local function alive(pid)
      return vim.uv.kill(pid, 0) == 0
    end

    local function seed(owner, watcher_pid)
      write_file(dir .. "/" .. owner .. ".watcher.pid", tostring(watcher_pid))
      write_file(dir .. "/" .. owner .. ".watcher.log", "")
      write_file(dir .. "/" .. owner .. "-claude-events-session-s1.jsonl", "{}\n")
    end

    before_each(function()
      procs = {}
      tmpdir = vim.fn.tempname() .. "-reap"
      dir = tmpdir .. "/cache/harness"
      vim.fn.mkdir(dir, "p")
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
      for _, p in ipairs(procs) do
        pcall(vim.uv.kill, p.pid, 9)
        pcall(function()
          p.handle:close()
        end)
      end
      vim.fn.delete(tmpdir, "rf")
    end)

    it("Given a dead owner nvim, Then its watcher is killed and its log, pidfile and sidecars are removed", function()
      local owner = dead_pid()
      local orphan = sleeper()
      seed(owner, orphan)
      local orig_cmd = watcher._process_command
      watcher._process_command = function(pid)
        if pid == orphan then
          return "inotifywait inotifywait -m -r /p"
        end
        return orig_cmd(pid)
      end

      watcher._reap_dead_watchers(vim.fn.getpid())

      assert.is_true(
        vim.wait(2000, function()
          return not alive(orphan)
        end),
        "orphaned watcher must be killed"
      )
      assert.is_false(exists(dir .. "/" .. owner .. ".watcher.pid"))
      assert.is_false(exists(dir .. "/" .. owner .. ".watcher.log"))
      assert.is_false(exists(dir .. "/" .. owner .. "-claude-events-session-s1.jsonl"))
      assert.is_true(exists(dir), "the directory itself is kept")
      watcher._process_command = orig_cmd
    end)

    it(
      "Given a dead owner whose recorded watcher pid is now an unrelated live process, Then that process survives and the stale files are removed",
      function()
        local owner = dead_pid()
        local unrelated = sleeper()
        seed(owner, unrelated)

        watcher._reap_dead_watchers(vim.fn.getpid())
        vim.wait(200)

        assert.is_true(alive(unrelated), "an unrelated process is never signaled")
        assert.is_false(exists(dir .. "/" .. owner .. ".watcher.pid"))
        assert.is_false(exists(dir .. "/" .. owner .. ".watcher.log"))
        assert.is_false(exists(dir .. "/" .. owner .. "-claude-events-session-s1.jsonl"))
      end
    )

    it("Given a dead owner's pidfile naming this nvim's pid, Then this nvim is never signaled", function()
      local owner = dead_pid()
      local me = vim.fn.getpid()
      seed(owner, me)
      local orig_kill, orig_cmd = vim.uv.kill, watcher._process_command
      local signaled = {}
      vim.uv.kill = function(pid, sig)
        if sig ~= 0 then
          signaled[#signaled + 1] = pid
          return 0
        end
        return orig_kill(pid, sig)
      end
      watcher._process_command = function()
        return "inotifywait inotifywait -m -r /p"
      end
      local ok, err = pcall(watcher._reap_dead_watchers, me)
      vim.uv.kill, watcher._process_command = orig_kill, orig_cmd

      assert.is_true(ok, tostring(err))
      assert.are.same({}, signaled)
      assert.is_false(exists(dir .. "/" .. owner .. ".watcher.pid"))
    end)

    it("recognizes inotifywait and fswatch process lines only", function()
      assert.is_true(watcher._is_watcher_command("inotifywait inotifywait -m -r /p"))
      assert.is_true(watcher._is_watcher_command("/opt/homebrew/bin/fswatch /opt/homebrew/bin/fswatch -r /p"))
      assert.is_false(watcher._is_watcher_command("sleep sleep 60"))
      assert.is_false(watcher._is_watcher_command(""))
      assert.is_false(watcher._is_watcher_command(nil))
    end)

    it("Given a live owner nvim, Then its watcher and files are left alone", function()
      local owner = sleeper()
      local w = sleeper()
      seed(owner, w)

      watcher._reap_dead_watchers(vim.fn.getpid())

      assert.is_true(alive(w))
      assert.is_true(exists(dir .. "/" .. owner .. ".watcher.pid"))
      assert.is_true(exists(dir .. "/" .. owner .. ".watcher.log"))
      assert.is_true(exists(dir .. "/" .. owner .. "-claude-events-session-s1.jsonl"))
    end)

    it("never reaps this nvim's own files", function()
      local me = vim.fn.getpid()
      local w = sleeper()
      seed(me, w)

      watcher._reap_dead_watchers(me)

      assert.is_true(alive(w))
      assert.is_true(exists(dir .. "/" .. me .. ".watcher.pid"))
    end)

    it("Given a dead nvim's sidecar with no watcher pidfile, Then the sidecar is removed", function()
      local owner = dead_pid()
      local side = dir .. "/" .. owner .. "-pi-events-session-s1.jsonl"
      write_file(side, "{}\n")

      watcher._reap_dead_watchers(vim.fn.getpid())

      assert.is_false(exists(side))
    end)

    it("Given a live nvim's or this nvim's sidecar with no watcher pidfile, Then the sidecar is kept", function()
      local owner = sleeper()
      local me = vim.fn.getpid()
      local live_side = dir .. "/" .. owner .. "-pi-events-session-s1.jsonl"
      local own_side = dir .. "/" .. me .. "-pi-events-session-s1.jsonl"
      write_file(live_side, "{}\n")
      write_file(own_side, "{}\n")

      watcher._reap_dead_watchers(me)

      assert.is_true(exists(live_side))
      assert.is_true(exists(own_side))
    end)
  end)
end)
