local agent_state = require("harness-decorators.agent-state")
local display = require("harness-decorators.agent-display")
local decorators = require("harness-decorators")
local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")
local watcher = require("harness-decorators.watcher")
local term = require("harness-decorators.term")

describe("agent-state asynchronous Crush identity through the display", function()
  local originals, dir, old_cwd, old_buf, buf, callbacks, saved_active

  local function replace(object, key, value)
    originals[#originals + 1] = { object, key, object[key] }
    object[key] = value
  end

  before_each(function()
    originals, callbacks = {}, {}
    old_cwd, old_buf = vim.fn.getcwd(), vim.api.nvim_get_current_buf()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.crush", "p")
    vim.fn.writefile({}, dir .. "/.crush/crush.db")
    vim.fn.chdir(dir)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    display.stop_timer()
    display._reset()
    term._reset()
    require("harness-decorators.crush.state")._reset()
    saved_active = active.get()
    active.set("crush")
    replace(watcher, "pinned_jsonl_path", nil)
    replace(utils, "sqlite_open_ro", function()
      return nil, "native reader unavailable"
    end)
    local executable = utils.command_executable
    replace(utils, "command_executable", function(cmd)
      return cmd == "sqlite3" or executable(cmd)
    end)
    replace(agent_state, "pid_for_buf", function()
      return 1234
    end)
    replace(agent_state, "ps_snapshot", function()
      return ""
    end)
    replace(require("snacks.terminal"), "open", function()
      return {
        buf = buf,
        buf_valid = function(self)
          return vim.api.nvim_buf_is_valid(self.buf)
        end,
        show = function() end,
        focus = function() end,
      }
    end)
    replace(vim, "system", function(cmd, _, callback)
      assert.are.equal("sqlite3", cmd[1])
      assert.are.equal("-readonly", cmd[2])
      assert.are.equal(dir .. "/.crush/crush.db", cmd[3])
      callbacks[#callbacks + 1] = callback
      return {}
    end)
    term.open("crush")
  end)

  after_each(function()
    active.set(saved_active)
    display.stop_timer()
    display._reset()
    require("harness-decorators.crush.state")._reset()
    term._reset()
    for i = #originals, 1, -1 do
      local saved = originals[i]
      saved[1][saved[2]] = saved[3]
    end
    vim.fn.chdir(old_cwd)
    if vim.api.nvim_buf_is_valid(old_buf) then
      vim.api.nvim_set_current_buf(old_buf)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  local function round(query_count)
    display.refresh()
    assert.are.equal(query_count, #callbacks, "each display poll must reach the real Crush CLI reader")
    assert.is_not_nil(display.status("crush"))
  end

  it(
    "Given delayed CLI ids, When display polls again, Then the session slot updates and a failed refresh retains the id",
    function()
      assert.are.equal(buf, term.bufnr("crush"))
      assert.are.equal(dir, term.cwd("crush"))
      assert.is_true(vim.tbl_contains(utils.list_harnesses(), "crush"), "the real harness roster must include Crush")
      round(1)
      assert.is_nil(display.status("crush").session_id)
      assert.truthy(decorators.session_component("frame"):find(" crush$"))

      callbacks[1]({ code = 0, stdout = "delayed-crush-session\n" })
      assert.is_nil(display.status("crush").session_id, "a CLI callback alone must not replace the display's poll map")
      round(2)
      assert.are.equal("delayed-crush-session", display.status("crush").session_id)
      assert.truthy(decorators.session_component("frame"):find(" delayed%-crush%-session$"))

      callbacks[2]({ code = 1, stdout = "" })
      round(3)
      assert.are.equal("delayed-crush-session", display.status("crush").session_id)
      assert.truthy(decorators.session_component("frame"):find(" delayed%-crush%-session$"))
      callbacks[3]({ code = 1, stdout = "" })
    end
  )
end)
