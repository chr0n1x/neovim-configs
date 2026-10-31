-- Contract for M.shutdown() (bound to <leader>qq via the HarnessShutdown user command).
--
-- The spec drives M.shutdown() with a real terminal job in a state.table entry and a real
-- inotifywait spawned via watcher.start, and
-- asserts that by the time shutdown returns, every side effect is verifiably complete:
-- the harness process is dead, the inotify log and pidfile are gone from disk, and the
-- watcher module is left stopped. The actual :qa! is stubbed (via M._quit_cmd) so the
-- test can inspect post-conditions; the contract is that the stub is only reachable
-- after all cleanup finished.

local active = require("harness-decorators.active")
local watcher = require("harness-decorators.watcher")
local state = require("harness-decorators.state")
local init = require("harness-decorators")

local function wait_for(cond, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local deadline = vim.uv.now() + timeout_ms
  while vim.uv.now() < deadline do
    if cond() then
      return true
    end
    vim.wait(50)
  end
  return false
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- The container's nvim build has no :linecount; readfile is the portable way to
-- count lines in an external file.
local function count_lines(path)
  return #vim.fn.readfile(path)
end

describe("M.shutdown: <leader>qq cleans up before :qa!", function()
  local quit_called
  local orig_quit_cmd
  local harness_buf
  local harness_jid
  local harness_pid
  local marker
  local log_path
  local pidfile_path
  local watcher_was_running

  setup(function()
    assert.are.equal("claude", active.get(), "shutdown spec assumes the claude adapter")

    quit_called = false
    orig_quit_cmd = init._quit_cmd
    init._quit_cmd = function()
      quit_called = true
    end

    -- Real terminal job running a long loop that appends to a marker file on each
    -- tick. After SIGTERM the file must stop growing - proof the process is actually
    -- dead, not merely signalled. jid dies on exit (jobpid raises E900), so the pid
    -- is captured up front; liveness is probed via uv.kill(pid, 0) (a 0 result
    -- means alive, nil means dead).
    marker = "/tmp/shutdown-spec-marker-" .. tostring(vim.fn.getpid()) .. ".txt"
    local cmd = "while true; do date >> '" .. marker .. "'; sleep 0.2; done"
    harness_buf = vim.api.nvim_create_buf(false, true)
    -- Focusing the buffer is what assigns it the job's channel (verified: without a
    -- window on it, bo.channel stays 0 even though jobpid works). cleanup() reads
    -- the channel from the buffer, so the spec must set it up the same way.
    vim.api.nvim_set_current_buf(harness_buf)
    harness_jid = vim.fn.jobstart({ "bash", "-c", cmd }, {
      out = "buffer",
      out_name = harness_buf,
      term = true,
    })
    assert.is_true(
      wait_for(function()
        local ok_pid, pid = pcall(vim.fn.jobpid, harness_jid)
        return ok_pid and pid > 0
      end),
      "harness job must be running before shutdown"
    )
    harness_pid = vim.fn.jobpid(harness_jid)
    -- cleanup() reads the channel from the buffer; confirm it is set so the spec
    -- exercises the same lookup path.
    assert.is_true(vim.bo[harness_buf].channel > 0, "harness buffer must have a channel")

    -- A real inotify watcher via the normal start path, so cleanup_files() has real
    -- <stdpath cache>/harness/<pid>.watcher.{log,pid} paths to remove. The claude adapter
    -- points at $HOME/.claude/projects, which the test container does not have -
    -- create it for the duration of the test.
    local ok_adapter, adapter = pcall(require, "harness-decorators." .. active.get())
    local projects_dir = ok_adapter and type(adapter.projects_dir) == "function" and adapter.projects_dir() or nil
    if projects_dir then
      vim.fn.mkdir(projects_dir, "p")
    end
    watcher.start()
    watcher_was_running = watcher.watcher_handle ~= nil
    log_path = watcher.watcher_log
    pidfile_path = watcher.watcher_pidfile
    assert.is_true(watcher_was_running, "watcher must have started (inotifywait available, projects dir exists)")
  end)

  teardown(function()
    init._quit_cmd = orig_quit_cmd
    state._reset()
    -- Kill by pid: the jid is already invalid after shutdown's SIGTERM reaped it.
    pcall(vim.uv.kill, harness_pid, "sigkill")
    if harness_buf and vim.api.nvim_buf_is_valid(harness_buf) then
      pcall(vim.api.nvim_buf_delete, harness_buf, { force = true })
    end
    -- Belt-and-braces: stop must be idempotent, but ensure no watcher lingers if the
    -- test itself failed mid-flight.
    pcall(watcher.stop)
    pcall(function()
      vim.fn.delete(marker)
    end)
    -- Remove the scratch projects dir only if it is still empty (no other spec
    -- populated it in the meantime).
    local ok_adapter2, adapter2 = pcall(require, "harness-decorators." .. active.get())
    local projects_dir2 = ok_adapter2 and type(adapter2.projects_dir) == "function" and adapter2.projects_dir() or nil
    if
      projects_dir2
      and vim.fn.isdirectory(projects_dir2)
      and vim.fn.empty(vim.fn.glob(projects_dir2 .. "/*", true)) == 1
    then
      pcall(vim.fn.rmdir, projects_dir2)
    end
  end)

  it(
    "Given a live harness job and a running inotify watcher, When M.shutdown() is called, Then the job is dead, the log and pidfile are gone, and the watcher is stopped before :qa! is issued",
    function()
      assert.is_true(watcher_was_running, "precondition: watcher was running")
      assert.is_true(file_exists(log_path), "precondition: log file exists on disk")
      assert.is_true(file_exists(pidfile_path), "precondition: pidfile exists on disk")

      -- Seed a state entry exactly as term.lua would, so cleanup() iterates over it.
      state.entry("claude").inst = { buf = harness_buf }

      -- Marker file must be growing while the harness job is alive.
      local count_before = count_lines(marker)
      assert.is_true(
        wait_for(function()
          return count_lines(marker) > count_before
        end),
        "harness job must be writing ticks before shutdown"
      )
      local stable_count = count_lines(marker)

      init.shutdown()

      -- 1. The harness process is actually dead, not merely signalled: uv.kill(pid, 0)
      --    reports it gone, and the marker file stops growing after a window longer
      --    than its 0.2s tick period.
      local ok_kill, kill_ret = pcall(vim.uv.kill, harness_pid, 0)
      assert.is_true(ok_kill, "uv.kill(pid, 0) must succeed")
      assert.is_nil(kill_ret, "harness pid must be dead by the time :qa! is issued")
      vim.wait(600)
      assert.are.equal(stable_count, count_lines(marker), "harness job must be stopped by the time :qa! is issued")

      -- 2. The inotify log and pidfile are removed from disk.
      assert.is_false(file_exists(log_path), "inotify log must be deleted before :qa! is issued")
      assert.is_false(file_exists(pidfile_path), "inotify pidfile must be deleted before :qa! is issued")

      -- 3. The watcher module is left in the stopped state.
      assert.is_nil(watcher.watcher_handle)
      assert.is_nil(watcher.watcher_pid)
      assert.is_nil(watcher.watcher_backend)

      -- 4. :qa! is reached (via the stubbed quit command) only after all of the above.
      assert.is_true(quit_called, ":qa! must be issued after cleanup completes")
    end
  )
end)
