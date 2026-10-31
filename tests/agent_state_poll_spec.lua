local agent_state = require("harness-decorators.agent-state")
local utils = require("harness-decorators.utils")

describe("agent-state poll inputs", function()
  local home, old_home, buf, originals, modules

  local function replace(object, key, value)
    originals[#originals + 1] = { object, key, object[key] }
    object[key] = value
  end

  local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end

  local function claude_session(sid)
    write(home .. "/.claude/sessions/1234.json", {
      vim.json.encode({ sessionId = sid, status = "busy" }),
    })
    local path = home .. "/.claude/projects/project/" .. sid .. ".jsonl"
    write(path, { '{"aiTitle":"Title for ' .. sid .. '"}' })
    return path
  end

  local function sqlite(rows, opened)
    replace(package.loaded, "lsqlite3", {
      open = function()
        opened.count = (opened.count or 0) + 1
        return {
          prepare = function(_, sql)
            opened[sql] = (opened[sql] or 0) + 1
            return {
              bind = function() end,
              get = function()
                if type(rows[sql]) == "function" then
                  return rows[sql]()
                end
                return rows[sql]
              end,
            }
          end,
          close = function()
            opened.closed = (opened.closed or 0) + 1
          end,
        }
      end,
    })
  end

  before_each(function()
    originals, modules = {}, {}
    home = vim.fn.tempname()
    old_home = os.getenv("HOME")
    vim.fn.setenv("HOME", home)
    buf = vim.api.nvim_create_buf(false, true)
    replace(package.loaded, "harness-decorators.term", {
      bufnr = function()
        return buf
      end,
      cwd = function()
        return home .. "/project"
      end,
    })
    replace(agent_state, "pid_for_buf", function()
      return 1234
    end)
    for _, name in ipairs({ "claude", "copilot", "crush", "maki", "pi", "pig" }) do
      local key = "harness-decorators." .. name .. ".state"
      modules[key] = package.loaded[key]
      package.loaded[key] = nil
    end
  end)

  after_each(function()
    for i = #originals, 1, -1 do
      local entry = originals[i]
      entry[1][entry[2]] = entry[3]
    end
    for _, name in ipairs({ "claude", "copilot", "crush", "maki", "pi", "pig" }) do
      local key = "harness-decorators." .. name .. ".state"
      package.loaded[key] = modules[key]
    end
    vim.fn.setenv("HOME", old_home)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(home, "rf")
  end)

  it("Given the same claude session, When two polls run, Then the project jsonl is globbed once", function()
    write(home .. "/.claude/sessions/1234.json", {
      vim.json.encode({ sessionId = "memo-session", status = "busy" }),
    })
    write(home .. "/.claude/projects/project/memo-session.jsonl", { '{"aiTitle":"Memo title"}' })
    local glob, calls = vim.fn.globpath, 0
    replace(vim.fn, "globpath", function(...)
      calls = calls + 1
      return glob(...)
    end)
    assert.are.equal("Memo title", agent_state.poll("claude", "").label)
    assert.are.equal("Memo title", agent_state.poll("claude", "").label)
    assert.are.equal(1, calls, "the same session must reuse its project path")
  end)

  it("Given claude status and label, When polled, Then its session json is read once", function()
    claude_session("shared")
    local read, calls = utils.read_json_file, 0
    replace(utils, "read_json_file", function(...)
      calls = calls + 1
      return read(...)
    end)
    local result = agent_state.poll("claude", "")
    assert.are.equal("working", result.status)
    assert.are.equal("Title for shared", result.label)
    assert.are.equal(1, calls, "status and label must share the session entry")
  end)

  it("Given copilot status and label, When polled, Then its sessions root is walked once", function()
    local dir = home .. "/.copilot/session-state/abcdef123456"
    write(dir .. "/inuse.1234.lock", {})
    write(dir .. "/events.jsonl", { '{"type":"assistant.turn_start"}' })
    local walk, calls = vim.fs.dir, 0
    replace(vim.fs, "dir", function(...)
      calls = calls + 1
      return walk(...)
    end)
    local result = agent_state.poll("copilot", "")
    assert.are.equal("working", result.status)
    assert.are.equal("abcdef12", result.label)
    assert.are.equal(1, calls, "status and label must share the selected directory")
  end)

  it("Given pushed pi state, When polled, Then status and label share one bridge lookup", function()
    local calls = 0
    replace(package.loaded, "harness-decorators.pi.follow", {
      session_for_cwd = function()
        calls = calls + 1
        return { status = "idle", session_id = "abcdef12-3456" }
      end,
      short_uuid = function(id)
        return id:sub(1, 8)
      end,
    })
    local result = agent_state.poll("pi", "")
    assert.are.equal("idle", result.status)
    assert.are.equal("abcdef12", result.label)
    assert.are.equal(1, calls, "status and label must share pushed state")
  end)

  it("Given pig status and label, When polled, Then its session directory is walked once", function()
    local dir = home .. "/.pig/agent/sessions/--" .. (home .. "/project"):sub(2):gsub("/", "-") .. "--"
    write(dir .. "/2026-01-01_abcdef12-3456.jsonl", {
      '{"type":"message","message":{"role":"assistant","stopReason":"stop"}}',
    })
    local walk, calls = vim.fs.dir, 0
    replace(vim.fs, "dir", function(...)
      calls = calls + 1
      return walk(...)
    end)
    local result = agent_state.poll("pig", "")
    assert.are.equal("idle", result.status)
    assert.are.equal("abcdef12", result.label)
    assert.are.equal(1, calls, "status and label must share the session file")
  end)

  it("Given unchanged claude title metadata, When polled twice, Then the title tail is read once", function()
    local path = claude_session("cached")
    local read, calls = utils.read_tail_lines, 0
    replace(utils, "read_tail_lines", function(...)
      calls = calls + 1
      return read(...)
    end)
    assert.are.equal("Title for cached", agent_state.poll("claude", "").label)
    assert.are.equal("Title for cached", agent_state.poll("claude", "").label)
    assert.are.equal(1, calls, "unchanged label files must not be reread")
    write(path, { '{"aiTitle":"Updated title"}' })
    local time = os.time() + 10
    vim.uv.fs_utime(path, time, time)
    assert.are.equal("Updated title", agent_state.poll("claude", "").label)
    claude_session("another")
    assert.are.equal("Title for another", agent_state.poll("claude", "").label)
    assert.are.equal(3, calls)
  end)

  it("Given an unchanged maki session, When polled twice, Then its title is read once", function()
    local dir = home .. "/.maki/sessions"
    replace(vim.env, "XDG_STATE_HOME", nil)
    write(dir .. "/cwd_latest.json", { vim.json.encode({ [home .. "/project"] = "maki-session" }) })
    local path = dir .. "/maki-session.jsonl"
    write(path, { '{"t":"meta","title":"Maki title"}' })
    local read, calls = utils.read_tail_lines, 0
    replace(utils, "read_tail_lines", function(...)
      calls = calls + 1
      return read(...)
    end)
    assert.are.equal("Maki title", agent_state.poll("maki", "").label)
    assert.are.equal("Maki title", agent_state.poll("maki", "").label)
    assert.are.equal(1, calls, "unchanged maki titles must not be reread")
    write(path, { '{"t":"meta","title":"Renamed maki"}' })
    vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)
    assert.are.equal("Renamed maki", agent_state.poll("maki", "").label)
  end)

  it("Given crush status, label and id, When polled, Then they share one read-only database", function()
    write(home .. "/project/.crush/crush.db", {})
    local opened = {}
    sqlite({
      ["SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1"] = {},
      ["SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1"] = { "Crush title" },
      ["SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1"] = { "crush-session" },
    }, opened)
    local result = agent_state.poll("crush", "")
    assert.are.equal("working", result.status)
    assert.are.equal("Crush title", result.label)
    assert.are.equal("crush-session", result.session_id)
    assert.are.equal(1, opened.count, "one poll must open the project database once")
    assert.are.equal(1, opened.closed)
    assert.are.equal("Crush title", agent_state.poll("crush", "").label)
    assert.are.equal(1, opened["SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1"])
  end)

  it("Given a cached copilot summary, When its WAL changes, Then the label is refreshed", function()
    local dir = home .. "/.copilot/session-state/abcdef123456"
    write(dir .. "/inuse.1234.lock", {})
    local path = home .. "/.copilot/session-store.db"
    write(path, {})
    local rows = { ["SELECT summary FROM sessions WHERE id=?"] = "First summary" }
    local opened = {}
    sqlite(rows, opened)
    assert.are.equal("First summary", agent_state.poll("copilot", "").label)
    assert.are.equal("First summary", agent_state.poll("copilot", "").label)
    assert.are.equal(1, opened.count, "unchanged sqlite labels must not be reread")
    rows["SELECT summary FROM sessions WHERE id=?"] = "New summary"
    write(path .. "-wal", { "changed" })
    assert.are.equal("New summary", agent_state.poll("copilot", "").label)
    assert.are.equal(2, opened.count)
  end)

  for _, name in ipairs({ "crush", "copilot" }) do
    it(
      "Given "
        .. name
        .. "'s available reader throws on its first open, When polled without file changes, Then it retries and caches the recovered title",
      function()
        local sql, fallback
        local rows = {}
        if name == "crush" then
          write(home .. "/project/.crush/crush.db", {})
          rows["SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1"] = { "crush-session" }
          rows["SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1"] = {}
          sql = "SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1"
          replace(utils, "command_executable", function()
            return false
          end)
          replace(vim, "notify", function() end)
        else
          write(home .. "/.copilot/session-state/abcdef123456/inuse.1234.lock", {})
          write(home .. "/.copilot/session-state/abcdef123456/events.jsonl", { '{"type":"assistant.turn_start"}' })
          write(home .. "/.copilot/session-store.db", {})
          sql = "SELECT summary FROM sessions WHERE id=?"
          fallback = "abcdef12"
        end
        rows[sql] = name == "crush" and { "Recovered title" } or "Recovered title"
        local opened = {}
        sqlite(rows, opened)
        local reader = package.loaded.lsqlite3
        local native_open, attempts = reader.open, 0
        replace(reader, "open", function(...)
          attempts = attempts + 1
          if attempts == 1 then
            error("temporary database open failure")
          end
          return native_open(...)
        end)

        for i = 1, 3 do
          local result = agent_state.poll(name, "")
          local expected = "Recovered title"
          if i == 1 then
            expected = fallback
          end
          assert.are.equal(expected, result.label)
          if name == "copilot" or i > 1 then
            assert.are.equal("working", result.status)
          end
        end
        assert.are.equal(name == "crush" and 3 or 2, attempts)
        assert.are.equal(attempts - 1, opened.count, "only successful opens yield handles")
        assert.are.equal(opened.count, opened.closed, "every successful handle must close")
        assert.are.equal(1, opened[sql], "the recovered title is cached after one successful query")
      end
    )

    it(
      "Given " .. name .. "'s first label query fails, When polled again without file changes, Then it retries",
      function()
        local sql, fallback
        local rows = {}
        if name == "crush" then
          write(home .. "/project/.crush/crush.db", {})
          rows["SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1"] = { "crush-session" }
          rows["SELECT finished_at FROM messages ORDER BY created_at DESC, rowid DESC LIMIT 1"] = {}
          sql = "SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1"
        else
          write(home .. "/.copilot/session-state/abcdef123456/inuse.1234.lock", {})
          write(home .. "/.copilot/session-store.db", {})
          sql = "SELECT summary FROM sessions WHERE id=?"
          fallback = "abcdef12"
        end
        local calls = 0
        rows[sql] = function()
          calls = calls + 1
          if calls == 1 then
            error("temporary label query failure")
          end
          return name == "crush" and { "Recovered title" } or "Recovered title"
        end
        local opened = {}
        sqlite(rows, opened)
        assert.are.equal(fallback, agent_state.poll(name, "").label)
        assert.are.equal("Recovered title", agent_state.poll(name, "").label)
        assert.are.equal("Recovered title", agent_state.poll(name, "").label)
        assert.are.equal(2, calls, "failed reads must retry, then successful reads may be cached")
        assert.are.equal(opened.count, opened.closed, "every borrowed database must close")
      end
    )

    it(
      "Given " .. name .. "'s label query succeeds without a title, When polled twice, Then absence is cached",
      function()
        local sql, fallback
        local rows = {}
        if name == "crush" then
          write(home .. "/project/.crush/crush.db", {})
          rows["SELECT id FROM sessions ORDER BY updated_at DESC LIMIT 1"] = { "empty-title-session" }
          sql = "SELECT title FROM sessions ORDER BY updated_at DESC LIMIT 1"
        else
          write(home .. "/.copilot/session-state/abcdef123456/inuse.1234.lock", {})
          write(home .. "/.copilot/session-store.db", {})
          sql = "SELECT summary FROM sessions WHERE id=?"
          fallback = "abcdef12"
        end
        local opened = {}
        sqlite(rows, opened)
        assert.are.equal(fallback, agent_state.poll(name, "").label)
        assert.are.equal(fallback, agent_state.poll(name, "").label)
        assert.are.equal(1, opened[sql], "a successful query with no title may be cached")
      end
    )
  end

  for _, name in ipairs({ "claude", "maki" }) do
    it(
      "Given " .. name .. "'s title file cannot be opened once, When polled again, Then it retries unchanged metadata",
      function()
        local path, title
        if name == "claude" then
          path = claude_session("retry-title")
          title = "Title for retry-title"
        else
          local dir = home .. "/.maki/sessions"
          replace(vim.env, "XDG_STATE_HOME", nil)
          write(dir .. "/cwd_latest.json", { vim.json.encode({ [home .. "/project"] = "retry-title" }) })
          path = dir .. "/retry-title.jsonl"
          title = "Recovered maki"
          write(path, { '{"t":"meta","title":"Recovered maki"}' })
        end
        local open, calls = io.open, 0
        replace(io, "open", function(file, ...)
          if file == path then
            calls = calls + 1
            if calls == 1 then
              return nil, "temporarily unreadable"
            end
          end
          return open(file, ...)
        end)
        assert.is_nil(agent_state.poll(name, "").label)
        assert.are.equal(title, agent_state.poll(name, "").label)
        assert.are.equal(title, agent_state.poll(name, "").label)
        assert.are.equal(2, calls, "an unreadable title must not be cached as absent")
      end
    )

    it("Given " .. name .. "'s readable file has no title, When polled twice, Then absence is cached", function()
      local path
      if name == "claude" then
        path = claude_session("no-title")
      else
        local dir = home .. "/.maki/sessions"
        replace(vim.env, "XDG_STATE_HOME", nil)
        write(dir .. "/cwd_latest.json", { vim.json.encode({ [home .. "/project"] = "no-title" }) })
        path = dir .. "/no-title.jsonl"
      end
      write(path, { '{"type":"message"}' })
      local open, calls = io.open, 0
      replace(io, "open", function(file, ...)
        if file == path then
          calls = calls + 1
        end
        return open(file, ...)
      end)
      assert.is_nil(agent_state.poll(name, "").label)
      assert.is_nil(agent_state.poll(name, "").label)
      assert.are.equal(1, calls, "a successful read with no title may be cached")
    end)
  end
end)
