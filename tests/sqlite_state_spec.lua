-- Pins the SQLite reads in crush/state.lua and copilot/state.lua with a fake lsqlite3 (the container
-- has none) and a stubbed sqlite3 CLI.

local function fake_sqlite(rows, opened)
  return {
    open = function(uri)
      opened[#opened + 1] = uri
      return {
        prepare = function(_, sql)
          if rows[sql] == "error" then
            error("boom")
          end
          return {
            bind = function() end,
            get = function()
              return rows[sql]
            end,
          }
        end,
        close = function()
          opened.closed = (opened.closed or 0) + 1
        end,
      }
    end,
  }
end

local STATUS_SQL = "SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1"
local TITLE_SQL = "SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1"
local ID_SQL = "SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1"

describe("sqlite-backed state adapters", function()
  local utils = require("harness-decorators.utils")
  local home, orig_home, cwd, crush, copilot, opened
  local orig_executable, orig_system, orig_notify, orig_command_executable

  local function use_sqlite(rows)
    opened = {}
    package.loaded["lsqlite3"] = rows and fake_sqlite(rows, opened) or nil
    package.preload["lsqlite3"] = nil
  end

  before_each(function()
    home = vim.fn.tempname() .. "-sqlite"
    cwd = home .. "/proj"
    vim.fn.mkdir(cwd .. "/.crush", "p")
    vim.fn.writefile({}, cwd .. "/.crush/crush.db")
    orig_home = os.getenv("HOME")
    vim.fn.setenv("HOME", home)
    orig_executable, orig_system, orig_notify = vim.fn.executable, vim.system, vim.notify
    orig_command_executable = utils.command_executable
    crush = require("harness-decorators.crush.state")
    copilot = require("harness-decorators.copilot.state")
    crush._reset()
  end)

  after_each(function()
    vim.fn.setenv("HOME", orig_home)
    vim.fn.executable, vim.system, vim.notify = orig_executable, orig_system, orig_notify
    utils.command_executable = orig_command_executable
    package.loaded["lsqlite3"] = nil
    vim.fn.delete(home, "rf")
  end)

  describe("crush.status", function()
    it("Given the newest message has a NULL finished_at, Then working", function()
      use_sqlite({ [STATUS_SQL] = {} })
      assert.are.equal("working", crush.status(1, cwd))
      assert.are.equal("file:" .. cwd .. "/.crush/crush.db?mode=ro", opened[1])
      assert.are.equal(1, opened.closed)
    end)

    it("Given a finished newest message or no messages, Then idle", function()
      use_sqlite({ [STATUS_SQL] = { 123 } })
      assert.are.equal("idle", crush.status(1, cwd))
      use_sqlite({})
      assert.are.equal("idle", crush.status(1, cwd))
    end)

    it("Given a failing query, no lsqlite3, or no project db, Then unknown", function()
      use_sqlite({ [STATUS_SQL] = "error" })
      assert.are.equal("unknown", crush.status(1, cwd))
      assert.are.equal(1, opened.closed)
      use_sqlite(nil)
      assert.are.equal("unknown", crush.status(1, cwd))
      use_sqlite({ [STATUS_SQL] = {} })
      assert.are.equal("unknown", crush.status(1, home .. "/nodb"))
    end)
  end)

  describe("crush.label", function()
    it("Given a titled session, Then the title; empty title or no lsqlite3, Then nil", function()
      use_sqlite({ [TITLE_SQL] = { "Fix bug" } })
      assert.are.equal("Fix bug", crush.label(1, cwd))
      use_sqlite({ [TITLE_SQL] = { "" } })
      assert.is_nil(crush.label(1, cwd))
      use_sqlite(nil)
      assert.is_nil(crush.label(1, cwd))
    end)
  end)

  describe("crush.session_id", function()
    it("Given lsqlite3, Then the newest session id", function()
      use_sqlite({ [ID_SQL] = { "sess-1" } })
      assert.are.equal("sess-1", crush.session_id(1, cwd))
    end)

    it("Given a pending CLI query, When polled, Then it never waits and exposes the callback id next time", function()
      use_sqlite(nil)
      local argv, callback, calls
      calls = 0
      utils.command_executable = function()
        return true
      end
      vim.fn.executable = function()
        return 1
      end
      vim.system = function(cmd, _, cb)
        calls = calls + 1
        argv = cmd
        callback = cb
        return {
          wait = function()
            error("the statusline must not wait for sqlite3")
          end,
        }
      end
      local ok, id = pcall(crush.session_id, 1, cwd)
      assert(ok, id)
      assert.is_nil(id)
      assert.is_nil(crush.session_id(1, cwd))
      assert.are.equal(1, calls, "a pending query must not spawn another process")
      assert.is_function(callback)
      callback({ code = 0, stdout = "  sess-cli\n" })
      assert.are.equal("sess-cli", crush.session_id(1, cwd))
      assert.are.same({ "sqlite3", "-readonly", cwd .. "/.crush/crush.db", ID_SQL }, argv)
      assert.are.equal(2, calls)
      callback({ code = 1, stdout = "" })
      assert.are.equal("sess-cli", crush.session_id(1, cwd), "a failed refresh must keep the last known id")
    end)

    it("Given no reader at all, Then nil and a single warning", function()
      use_sqlite(nil)
      local notes = 0
      utils.command_executable = function()
        return false
      end
      vim.notify = function()
        notes = notes + 1
      end
      assert.is_nil(crush.session_id(1, cwd))
      assert.is_nil(crush.session_id(1, cwd))
      assert.are.equal(1, notes)
    end)

    it("Given the cached executable helper rejects sqlite3, When resolving an id, Then no PATH probe runs", function()
      use_sqlite(nil)
      local helpers, probes = 0, 0
      utils.command_executable = function(command)
        assert.are.equal("sqlite3", command)
        helpers = helpers + 1
        return false
      end
      vim.fn.executable = function()
        probes = probes + 1
        return 0
      end
      vim.notify = function() end
      assert.is_nil(crush.session_id(1, cwd))
      assert.are.equal(1, helpers, "the adapter must use utils.command_executable")
      assert.are.equal(0, probes)
    end)
  end)

  describe("copilot.label", function()
    local sid = "abcdef1234567890"

    before_each(function()
      local dir = home .. "/.copilot/session-state/" .. sid
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({}, dir .. "/inuse.4321.lock")
      vim.fn.writefile({}, home .. "/.copilot/session-store.db")
    end)

    it("Given a summary in the store, Then the summary, read read-only", function()
      use_sqlite({ ["SELECT summary FROM sessions WHERE id=?"] = "Refactor x" })
      assert.are.equal("Refactor x", copilot.label(4321, "/x"))
      assert.are.equal("file:" .. home .. "/.copilot/session-store.db?mode=ro", opened[1])
      assert.are.equal(1, opened.closed)
    end)

    it("Given no summary or no lsqlite3, Then the 8-char session id", function()
      use_sqlite({})
      assert.are.equal("abcdef12", copilot.label(4321, "/x"))
      use_sqlite(nil)
      assert.are.equal("abcdef12", copilot.label(4321, "/x"))
    end)
  end)
end)
