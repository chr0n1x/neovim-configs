-- watcher.start(): backend choice and spawn arguments per OS, and where the watcher's files
-- live. vim.fn.exepath decides which backends are "installed", vim.uv.os_uname decides the OS,
-- and vim.uv.spawn is replaced by a recorder that starts `sleep 60` instead, so the pid stop()
-- sends SIGTERM to belongs to this spec. stdpath("cache") points at a temp dir.

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")

describe("watcher.start", function()
  local adapter
  local tmpdir, projects, cache
  local installed, sysname, spawned, logs
  local orig = {}

  before_each(function()
    assert.are.equal("claude", utils.harness, "watcher start spec assumes the claude adapter")
    pcall(watcher.stop)
    -- Other specs switch harnesses, which reloads the adapter module; take the one the watcher uses.
    watcher.set_harness("claude")
    adapter = require("harness-decorators.claude")
    tmpdir = vim.fn.tempname() .. "-wstart"
    projects = tmpdir .. "/projects"
    cache = tmpdir .. "/cache"
    vim.fn.mkdir(projects, "p")
    installed, sysname, spawned, logs = {}, "Linux", {}, {}

    orig.exepath = vim.fn.exepath
    orig.stdpath = vim.fn.stdpath
    orig.uname = vim.uv.os_uname
    orig.spawn = vim.uv.spawn
    orig.projects_dir = adapter.projects_dir
    orig.flat = adapter.flat_sessions_dir
    orig.log = utils.log
    orig.user = vim.fn.getenv("USER")

    vim.fn.setenv("USER", "nvimtest")
    vim.fn.exepath = function(bin)
      return installed[bin] and ("/usr/bin/" .. bin) or ""
    end
    vim.fn.stdpath = function(what)
      if what == "cache" then
        return cache
      end
      return orig.stdpath(what)
    end
    vim.uv.os_uname = function()
      return { sysname = sysname }
    end
    vim.uv.spawn = function(cmd, opts, on_exit)
      spawned[#spawned + 1] = { cmd = cmd, args = opts.args }
      return orig.spawn("sleep", { args = { "60" } }, on_exit)
    end
    adapter.projects_dir = function()
      return projects
    end
    utils.log = function(msg, level)
      logs[#logs + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    pcall(watcher.stop)
    vim.fn.exepath = orig.exepath
    vim.fn.stdpath = orig.stdpath
    vim.uv.os_uname = orig.uname
    vim.uv.spawn = orig.spawn
    adapter.projects_dir = orig.projects_dir
    adapter.flat_sessions_dir = orig.flat
    utils.log = orig.log
    vim.fn.setenv("USER", orig.user)
    vim.fn.delete(tmpdir, "rf")
  end)

  local function has(list, value)
    return vim.tbl_contains(list, value)
  end

  describe("backend choice", function()
    it("inotifywait wins when both are installed", function()
      installed = { inotifywait = true, fswatch = true }
      watcher.start()
      assert.are.equal(1, #spawned)
      assert.are.equal("inotifywait", spawned[1].cmd)
      assert.are.equal("inotifywait", watcher.watcher_backend)
      assert.are.equal("close_write,moved_to", spawned[1].args[4])
    end)

    it("flat adapters add modify to the inotify events", function()
      installed = { inotifywait = true }
      adapter.flat_sessions_dir = true
      watcher.start()
      assert.are.equal("close_write,moved_to,modify", spawned[1].args[4])
    end)

    it("fswatch on Darwin watches the root without -r", function()
      installed = { fswatch = true }
      sysname = "Darwin"
      watcher.start()
      assert.are.equal("fswatch", spawned[1].cmd)
      assert.are.same({ "-l", "0.3", "--event", "Updated", projects }, spawned[1].args)
    end)

    it("fswatch on Linux gets -r", function()
      installed = { fswatch = true }
      watcher.start()
      assert.is_true(has(spawned[1].args, "-r"))
    end)

    it("fswatch on Linux with a flat adapter gets no -r", function()
      installed = { fswatch = true }
      adapter.flat_sessions_dir = true
      watcher.start()
      assert.is_false(has(spawned[1].args, "-r"))
    end)

    it("with neither backend, logs one WARN and following stays off", function()
      watcher.start()
      assert.are.equal(0, #spawned)
      assert.is_nil(watcher.watcher_handle)
      local warns = 0
      for _, l in ipairs(logs) do
        if l.level == vim.log.levels.WARN then
          warns = warns + 1
        end
      end
      assert.are.equal(1, warns)
    end)
  end)

  describe("files", function()
    local function exists(path)
      return vim.uv.fs_stat(path) ~= nil
    end

    it("puts the log and pidfile under stdpath('cache')/harness/ with a 0700 directory", function()
      installed = { inotifywait = true }
      watcher.start()
      local dir = cache .. "/harness/"
      assert.are.equal(dir, watcher.watcher_log:sub(1, #dir))
      assert.are.equal(dir, watcher.watcher_pidfile:sub(1, #dir))
      assert.is_true(exists(watcher.watcher_log))
      assert.is_true(exists(watcher.watcher_pidfile))
      local st = assert(vim.uv.fs_stat(cache .. "/harness"))
      assert.are.equal(tonumber("700", 8), bit.band(st.mode, tonumber("777", 8)))
    end)

    it("Given another instance's files, When this nvim stops and exits, Then only its own files are removed", function()
      installed = { inotifywait = true }
      watcher.start()
      local log, pidfile = watcher.watcher_log, watcher.watcher_pidfile
      local dir = cache .. "/harness"
      local me = vim.fn.getpid()
      -- A live process stands in for the other nvim, so the poll's reaper leaves it alone.
      local other_handle, other = orig.spawn("sleep", { args = { "60" } }, function() end)
      local own_sidecar = dir .. "/" .. me .. "-claude-events-session-s1.jsonl"
      local others = {
        dir .. "/" .. other .. ".watcher.log",
        dir .. "/" .. other .. ".watcher.pid",
        dir .. "/" .. other .. "-claude-events-session-s1.jsonl",
      }
      for _, p in ipairs({ own_sidecar, unpack(others) }) do
        local f = assert(io.open(p, "w"))
        f:close()
      end

      watcher.stop()
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "HarnessSidecarCleanup" })

      assert.is_false(exists(log))
      assert.is_false(exists(pidfile))
      assert.is_false(exists(own_sidecar))
      for _, p in ipairs(others) do
        assert.is_true(exists(p), p)
      end
      assert.is_true(exists(dir))
      vim.uv.kill(other, 9)
      other_handle:close()
    end)
  end)
end)
