local term = require("harness-decorators.term")

describe("env: fresh terminal spawn boundary", function()
  local originals, saved_env, buffers, calls
  local vars = {
    "CLAUDE_COMMAND",
    "CLAUDE_MODEL",
    "CLAUDE_CODE_TRACKING_ENABLED",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "COPILOT_COMMAND",
  }

  local function replace(object, key, value)
    originals[#originals + 1] = { object, key, object[key] }
    object[key] = value
  end

  local function snapshot()
    local env = {}
    for _, key in ipairs(vars) do
      env[key] = os.getenv(key) or vim.NIL
    end
    return env
  end

  before_each(function()
    originals, buffers, calls = {}, {}, {}
    saved_env = snapshot()
    for _, key in ipairs(vars) do
      vim.env[key] = nil
    end
    term._reset()
    replace(require("snacks.terminal"), "open", function(cmd, opts)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
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
  end)

  after_each(function()
    term._reset()
    for i = #originals, 1, -1 do
      local saved = originals[i]
      saved[1][saved[2]] = saved[3]
    end
    for key, value in pairs(saved_env) do
      vim.env[key] = value ~= vim.NIL and value or nil
    end
    for _, buf in ipairs(buffers) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)

  it(
    "Given a Claude model, When Claude then Copilot open, Then only Claude gets defaults and the parent stays unchanged",
    function()
      vim.env.CLAUDE_MODEL = "local-model"
      vim.env.CLAUDE_CODE_TRACKING_ENABLED = "true"
      local parent = snapshot()
      assert.is_not_nil(term.open("claude", { args = "--continue" }))
      assert.are.equal("claude --model local-model --continue", calls[1].cmd)
      assert.are.same({
        CLAUDE_CODE_TRACKING_ENABLED = "false",
        ANTHROPIC_BASE_URL = "http://localhost:11434",
        ANTHROPIC_API_KEY = "",
        ANTHROPIC_AUTH_TOKEN = "ollama",
      }, calls[1].opts.env)
      assert.are.same(parent, snapshot())

      assert.is_not_nil(term.open("copilot"))
      assert.are.equal("copilot", calls[2].cmd)
      assert.is_nil(calls[2].opts.env)
      assert.are.same(parent, snapshot())
    end
  )

  it(
    "Given a live terminal, When reopened with changed vars and args, Then neither command nor env is prepared again",
    function()
      local env = require("harness-decorators.claude.env")
      local command, prepare_env = env.command, env.prepare_env
      local commanded, prepared = 0, 0
      replace(env, "command", function()
        commanded = commanded + 1
        return command()
      end)
      replace(env, "prepare_env", function()
        prepared = prepared + 1
        return prepare_env()
      end)
      local first = term.open("claude")
      assert.is_not_nil(first)
      vim.env.CLAUDE_COMMAND = "changed-wrapper"
      vim.env.CLAUDE_MODEL = "changed-model"
      assert.are.equal(first, term.open("claude", { args = "--continue" }))
      assert.are.equal(1, #calls)
      assert.are.equal(1, commanded)
      assert.are.equal(1, prepared)
    end
  )

  it(
    "Given a synthetic inherited auth token, When Claude opens, Then the token is not copied into Snacks opts",
    function()
      vim.env.CLAUDE_MODEL = "local-model"
      vim.env.ANTHROPIC_AUTH_TOKEN = "synthetic-parent-token"
      local parent = snapshot()
      assert.is_not_nil(term.open("claude"))
      assert.is_table(calls[1].opts.env)
      assert.is_nil(calls[1].opts.env.ANTHROPIC_AUTH_TOKEN)
      assert.are.same({
        CLAUDE_CODE_TRACKING_ENABLED = "false",
        ANTHROPIC_BASE_URL = "http://localhost:11434",
        ANTHROPIC_API_KEY = "",
      }, calls[1].opts.env)
      assert.are.same(parent, snapshot())
    end
  )

  it("Given a full Claude command and model, When opened, Then its override gets no default env keys", function()
    vim.env.CLAUDE_COMMAND = "claude-wrapper --custom"
    vim.env.CLAUDE_MODEL = "ignored-model"
    local parent = snapshot()
    assert.is_not_nil(term.open("claude"))
    assert.are.equal("claude-wrapper --custom", calls[1].cmd)
    assert.is_nil(calls[1].opts.env)
    assert.are.same(parent, snapshot())
  end)
end)

describe("env: real Snacks terminal jobs", function()
  local env_mod = "harness-decorators.maki.env"
  local saved_module, saved_probe, saved_notify, notes, files

  before_each(function()
    term._reset()
    saved_module = package.loaded[env_mod]
    saved_probe = os.getenv("HD_PROBE") or vim.NIL
    saved_notify = vim.notify
    notes, files = {}, {}
    vim.env.HD_PROBE = nil
    vim.notify = function(message, level)
      notes[#notes + 1] = { message, level }
    end
  end)

  after_each(function()
    term._reset()
    package.loaded[env_mod] = saved_module
    vim.env.HD_PROBE = saved_probe ~= vim.NIL and saved_probe or nil
    vim.notify = saved_notify
    for _, file in ipairs(files) do
      vim.fn.delete(file)
    end
  end)

  local function spawn(overrides, value)
    local file = vim.fn.tempname()
    files[#files + 1] = file
    package.loaded[env_mod] = {
      command = function()
        return "printf '%s' " .. value .. " > " .. vim.fn.shellescape(file) .. "; sleep 30"
      end,
      prepare_env = function()
        return overrides
      end,
    }
    local ok, inst = pcall(term.open, "maki")
    assert.is_true(ok, tostring(inst))
    assert.is_not_nil(inst, "the real Snacks terminal must open")
    local job = vim.bo[inst.buf].channel
    assert.is_true(job > 0)
    assert.is_true(
      vim.wait(2000, function()
        return vim.fn.filereadable(file) == 1
      end, 10),
      "the terminal job must write its probe"
    )
    assert.are.equal(-1, vim.fn.jobwait({ job }, 0)[1], "the terminal job must still be running")
    return file
  end

  it("Given an empty job env, When a real Snacks terminal opens, Then its job runs", function()
    local file = spawn({}, "'running'")
    assert.are.same({ "running" }, vim.fn.readfile(file))
  end)

  it(
    "Given a job-local probe, When real Snacks jobs open with and without overrides, Then only the first receives it",
    function()
      local file = spawn({ HD_PROBE = "job-local" }, '"$HD_PROBE"')
      assert.are.same({ "job-local" }, vim.fn.readfile(file))
      assert.is_nil(os.getenv("HD_PROBE"))
      term._reset()
      local sibling = spawn({}, '"${HD_PROBE-unset}"')
      assert.are.same({ "unset" }, vim.fn.readfile(sibling))
      assert.is_nil(os.getenv("HD_PROBE"))
    end
  )

  it("Given an env module without prepare_env, When opened, Then it reports no command and returns nil", function()
    package.loaded[env_mod] = {
      command = function()
        return "sleep 30"
      end,
    }
    local ok, inst = pcall(term.open, "maki")
    assert.is_true(ok, tostring(inst))
    assert.is_nil(inst)
    assert.are.same({ { "harness: no command for maki", vim.log.levels.ERROR } }, notes)
  end)
end)
