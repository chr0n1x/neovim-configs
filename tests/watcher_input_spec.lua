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

    it("Given the log grew by more than 64KB, Then it skips to the end and logs the skip", function()
      watcher.watcher_backend = "fswatch"
      write_file(log, string.rep("/p/h/a.jsonl\n", 6000))
      watcher._process_watcher_log()
      assert.are.same({}, got)
      assert.are.equal(vim.uv.fs_stat(log).size, watcher.watcher_last_pos)
      local found
      for _, l in ipairs(logs) do
        if tostring(l.msg):find("skipped", 1, true) and l.level == vim.log.levels.WARN then
          found = true
        end
      end
      assert.is_true(found, "expected a WARN log mentioning the skip")
    end)
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
  end)
end)
