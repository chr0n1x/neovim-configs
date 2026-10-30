local agent_state = require("harness-decorators.agent-state")
local utils = require("harness-decorators.utils")
local term = require("harness-decorators.term")

describe("agent-state polls the terminal's recorded cwd", function()
  local home, old_cwd, old_buf, originals, buffers, spawn, edited, later

  local function replace(object, key, value)
    originals[#originals + 1] = { object, key, object[key] }
    object[key] = value
  end

  local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end

  before_each(function()
    originals, buffers = {}, {}
    home = vim.fn.tempname()
    spawn, edited, later = home .. "/spawn", home .. "/edited", home .. "/later"
    for _, dir in ipairs({ spawn, edited, later }) do
      vim.fn.mkdir(dir, "p")
    end
    old_cwd, old_buf = vim.fn.getcwd(), vim.api.nvim_get_current_buf()
    replace(vim.env, "HOME", home)
    replace(vim.env, "XDG_STATE_HOME", nil)
    vim.fn.chdir(spawn)
    local scratch = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = scratch
    vim.api.nvim_set_current_buf(scratch)
    term._reset()
    replace(require("snacks.terminal"), "open", function()
      local buf = vim.api.nvim_create_buf(false, true)
      buffers[#buffers + 1] = buf
      return {
        buf = buf,
        buf_valid = function(self)
          return vim.api.nvim_buf_is_valid(self.buf)
        end,
        show = function() end,
        focus = function() end,
      }
    end)
    replace(agent_state, "pid_for_buf", function()
      return 1234
    end)
  end)

  after_each(function()
    term._reset()
    for i = #originals, 1, -1 do
      local saved = originals[i]
      saved[1][saved[2]] = saved[3]
    end
    vim.fn.chdir(old_cwd)
    if vim.api.nvim_buf_is_valid(old_buf) then
      vim.api.nvim_set_current_buf(old_buf)
    end
    for _, buf in ipairs(buffers) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    vim.fn.delete(home, "rf")
  end)

  for _, name in ipairs({ "crush", "pi", "pig", "maki" }) do
    it(
      "Given "
        .. name
        .. " opened before a cwd change, When polled from another file, Then its recorded cwd selects the session",
      function()
        local inst = term.open(name)
        assert.are.equal(spawn, term.cwd(name))
        local opened_at = term.opened_at(name)
        local expected_status, expected_label = "idle", "abcdef12"
        local opened = {}

        if name == "crush" then
          expected_status, expected_label = "working", "Spawn database"
          for _, cwd in ipairs({ spawn, edited, later }) do
            write(cwd .. "/.crush/crush.db", {})
          end
          replace(utils, "sqlite_open_ro", function(path)
            opened[#opened + 1] = path
            local correct = path == spawn .. "/.crush/crush.db"
            return {
              prepare = function(_, sql)
                return {
                  get = function()
                    if sql:find("SELECT title", 1, true) then
                      return { correct and "Spawn database" or "Wrong database" }
                    elseif sql:find("SELECT id", 1, true) then
                      return { correct and "spawn-session" or "wrong-session" }
                    end
                    return correct and {} or { 123 }
                  end,
                }
              end,
            }, function() end
          end)
        elseif name == "maki" then
          expected_label = "Spawn header"
          local dir = home .. "/.maki/sessions"
          for i, cwd in ipairs({ edited, later, spawn }) do
            write(dir .. "/" .. i .. ".jsonl", {
              vim.json.encode({ t = "header", cwd = cwd, created_at = opened_at }),
              vim.json.encode({ t = "meta", title = cwd == spawn and "Spawn header" or "Wrong header" }),
            })
          end
          write(dir .. "/cwd_latest.json", {
            vim.json.encode({ [spawn] = "1", [edited] = "1", [later] = "2" }),
          })
        else
          expected_status = name == "pig" and "working" or "idle"
          for _, cwd in ipairs({ spawn, edited, later }) do
            local encoded = cwd:sub(2):gsub("/", "-"):gsub("\\", "-"):gsub(":", "-")
            local id = cwd == spawn and "abcdef12-3456" or "ffffffff-3456"
            local path = home .. "/." .. name .. "/agent/sessions/--" .. encoded .. "--/2026-01-01_" .. id .. ".jsonl"
            write(path, {
              cwd == spawn and '{"type":"message","message":{"role":"user"}}'
                or '{"type":"message","message":{"role":"assistant","stopReason":"stop"}}',
            })
            vim.uv.fs_utime(path, opened_at, opened_at)
          end
        end

        local path = edited .. "/current.lua"
        write(path, { "return true" })
        local file_buf = vim.api.nvim_create_buf(false, true)
        buffers[#buffers + 1] = file_buf
        vim.api.nvim_buf_set_name(file_buf, path)
        vim.api.nvim_set_current_buf(file_buf)
        vim.fn.chdir(later)

        assert.are.equal(inst, term.open(name), "reopening must reuse the process from its original cwd")
        assert.are.equal(spawn, term.cwd(name))
        assert.are.equal(opened_at, term.opened_at(name))
        local result = agent_state.poll(name, "")
        assert.are.equal(expected_status, result.status)
        assert.are.equal(expected_label, result.label)
        if name == "crush" then
          assert.are.same({ spawn .. "/.crush/crush.db" }, opened)
          assert.are.equal("spawn-session", result.session_id)
        end
      end
    )
  end
end)
