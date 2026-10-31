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

  it(
    "Given a running harness from cwd A, When its float is hidden, minimized and restored after changing cwd, Then polls keep its original session until its terminal buffer is wiped",
    function()
      replace(require("snacks.terminal"), "open", function()
        local inst = {
          buf = vim.api.nvim_create_buf(false, true),
          opts = { border = "rounded", row = 2, col = 10, width = 40, height = 10 },
        }
        buffers[#buffers + 1] = inst.buf
        function inst:buf_valid()
          return vim.api.nvim_buf_is_valid(self.buf)
        end
        function inst:show()
          self.win = vim.api.nvim_open_win(self.buf, false, {
            relative = "editor",
            row = self.opts.row,
            col = self.opts.col,
            width = self.opts.width,
            height = self.opts.height,
            border = "rounded",
          })
        end
        function inst:hide()
          if self.win and vim.api.nvim_win_is_valid(self.win) then
            vim.api.nvim_win_close(self.win, true)
          end
          self.win = nil
        end
        function inst:focus() end
        inst:show()
        return inst
      end)

      local inst = term.open("pig")
      local record = require("harness-decorators.state").table.pig
      local buf, opened_at = inst.buf, term.opened_at("pig")
      for _, cwd in ipairs({ spawn, later }) do
        local encoded = cwd:sub(2):gsub("/", "-"):gsub("\\", "-"):gsub(":", "-")
        local id = cwd == spawn and "abcdef12-3456" or "ffffffff-3456"
        local path = home .. "/.pig/agent/sessions/--" .. encoded .. "--/2026-01-01_" .. id .. ".jsonl"
        write(path, { '{"type":"message","message":{"role":"user"}}' })
        vim.uv.fs_utime(path, opened_at, opened_at)
      end
      replace(os, "time", function()
        return opened_at + 60
      end)
      vim.fn.chdir(later)

      local function assert_inputs()
        assert.are.equal(record, require("harness-decorators.state").table.pig)
        assert.are.equal(inst, record.inst)
        assert.are.equal(buf, term.bufnr("pig"))
        assert.are.equal(spawn, term.cwd("pig"))
        assert.are.equal(opened_at, term.opened_at("pig"))
        assert.are.same({ { harness = "pig", bufnr = buf } }, term.list())
        local result = agent_state.poll("pig", "")
        assert.are.equal("working", result.status)
        assert.are.equal("abcdef12", result.label)
      end

      assert_inputs()
      term.hide("pig")
      assert.is_nil(inst.win)
      assert_inputs()
      term.show("pig")
      assert.is_true(vim.api.nvim_win_is_valid(inst.win))
      assert.is_true(term.minimize("pig"))
      assert.is_nil(inst.win)
      assert.is_true(vim.api.nvim_win_is_valid(inst._pill_win))
      assert.are_not.equal(buf, vim.api.nvim_win_get_buf(inst._pill_win))
      assert_inputs()
      term.show("pig")
      assert_inputs()
      assert.is_true(
        vim.wait(2000, function()
          return inst.win ~= nil and vim.api.nvim_win_is_valid(inst.win) and inst._pill_win == nil
        end, 10),
        "the same terminal must be restored from its bar"
      )
      assert_inputs()

      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_nil(require("harness-decorators.state").table.pig)
      assert.is_nil(term.bufnr("pig"))
      assert.is_nil(term.cwd("pig"))
      assert.is_nil(term.opened_at("pig"))
      assert.is_nil(agent_state.poll("pig", ""))
      assert.are.same({}, term.list())
    end
  )
end)
