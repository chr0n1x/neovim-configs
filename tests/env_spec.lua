local harnesses = { "claude", "copilot", "crush", "maki", "pi", "pig" }
local vars = {
  "LLAMA_DEFAULT_MODEL",
  "CLAUDE_CODE_TRACKING_ENABLED",
  "ANTHROPIC_BASE_URL",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "HD_ENV_INHERITED",
  "HD_ENV_LOCAL",
  "HD_ENV_EMPTY",
}
for _, harness in ipairs(harnesses) do
  local h = harness:upper()
  vim.list_extend(vars, { h .. "_COMMAND", h .. "_MODEL", "NVIM_LLM_HARNESS_" .. h .. "_PROVIDER_NAME" })
end

describe("env: callable commands and job-local overrides", function()
  local saved_env, saved_modules

  local function snapshot()
    local env = {}
    for _, k in ipairs(vars) do
      env[k] = os.getenv(k) or vim.NIL
    end
    return env
  end

  local function load_env(harness)
    local env = require("harness-decorators." .. harness .. ".env")
    assert.is_table(env, harness .. " env must expose command() and prepare_env()")
    return env
  end

  before_each(function()
    saved_env, saved_modules = snapshot(), {}
    for _, k in ipairs(vars) do
      vim.env[k] = nil
    end
    for _, harness in ipairs(harnesses) do
      local mod = "harness-decorators." .. harness .. ".env"
      saved_modules[mod] = package.loaded[mod] or false
      package.loaded[mod] = nil
    end
  end)

  after_each(function()
    for k, orig in pairs(saved_env) do
      vim.env[k] = orig ~= vim.NIL and orig or nil
    end
    for mod, orig in pairs(saved_modules) do
      package.loaded[mod] = orig or nil
    end
  end)

  it("Given a Claude model, When its env module is required, Then the parent env is unchanged", function()
    vim.env.CLAUDE_MODEL = "local-model"
    vim.env.CLAUDE_CODE_TRACKING_ENABLED = "true"
    local parent = snapshot()
    require("harness-decorators.claude.env")
    assert.are.same(parent, snapshot())
  end)

  for _, harness in ipairs(harnesses) do
    it(
      ("Given cached %s env, When command/model vars change, Then command() reads current values"):format(harness),
      function()
        local env = load_env(harness)
        local h = harness:upper()
        local parent = snapshot()
        assert.are.equal(harness, env.command())
        assert.are.same(parent, snapshot())

        vim.env[h .. "_COMMAND"] = harness .. " --wrapped"
        vim.env[h .. "_MODEL"] = "first-model"
        vim.env.LLAMA_DEFAULT_MODEL = "first-model"
        vim.env["NVIM_LLM_HARNESS_" .. h .. "_PROVIDER_NAME"] = "first-provider"
        assert.are.equal(harness .. " --wrapped", env.command())

        vim.env[h .. "_COMMAND"] = ""
        vim.env[h .. "_MODEL"] = "second-model"
        vim.env.LLAMA_DEFAULT_MODEL = "second-model"
        vim.env["NVIM_LLM_HARNESS_" .. h .. "_PROVIDER_NAME"] = "second-provider"
        parent = snapshot()
        local expected = harness
        if harness == "claude" then
          expected = harness .. " --model second-model"
        elseif harness == "maki" then
          expected = harness .. " -m second-model"
        elseif harness == "pi" or harness == "pig" then
          expected = harness .. " --provider second-provider --model second-model"
        end
        assert.are.equal(env, require("harness-decorators." .. harness .. ".env"))
        assert.are.equal(expected, env.command())
        assert.are.same(parent, snapshot())
      end
    )

    if harness ~= "claude" then
      it(
        ("Given %s and Claude vars, When preparing twice, Then each result is a fresh empty table"):format(harness),
        function()
          vim.env.CLAUDE_MODEL = "local-model"
          vim.env.CLAUDE_CODE_TRACKING_ENABLED = "true"
          local env = load_env(harness)
          local parent = snapshot()
          local first = env.prepare_env()
          assert.are.same({}, first)
          first.MARKER = "only-first"
          assert.are.same({}, env.prepare_env())
          assert.are.same(parent, snapshot())
        end
      )
    end
  end

  for _, model in ipairs({ false, "" }) do
    it(("Given Claude model %s, When preparing, Then only tracking is overridden"):format(tostring(model)), function()
      vim.env.CLAUDE_MODEL = model or nil
      vim.env.CLAUDE_CODE_TRACKING_ENABLED = "true"
      local env = load_env("claude")
      local parent = snapshot()
      assert.are.same({ CLAUDE_CODE_TRACKING_ENABLED = "false" }, env.prepare_env())
      assert.are.same(parent, snapshot())
    end)
  end

  it(
    "Given an empty Claude command and a model, When preparing, Then absent defaults are job-local and fresh",
    function()
      vim.env.CLAUDE_COMMAND = ""
      vim.env.CLAUDE_MODEL = "local-model"
      vim.env.CLAUDE_CODE_TRACKING_ENABLED = ""
      local env = load_env("claude")
      local parent = snapshot()
      local expected = {
        CLAUDE_CODE_TRACKING_ENABLED = "false",
        ANTHROPIC_BASE_URL = "http://localhost:11434",
        ANTHROPIC_API_KEY = "",
        ANTHROPIC_AUTH_TOKEN = "ollama",
      }
      local first = env.prepare_env()
      assert.are.same(expected, first)
      first.ANTHROPIC_AUTH_TOKEN = "only-first"
      assert.are.same(expected, env.prepare_env())
      assert.are.same(parent, snapshot())
    end
  )

  for _, key in ipairs({ "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN" }) do
    for _, value in ipairs({ "", "synthetic-parent-value" }) do
      it(("Given inherited %s %q, When preparing Claude, Then that value is not copied"):format(key, value), function()
        vim.env.CLAUDE_MODEL = "local-model"
        vim.env[key] = value
        local env = load_env("claude")
        local parent = snapshot()
        local expected = {
          CLAUDE_CODE_TRACKING_ENABLED = "false",
          ANTHROPIC_BASE_URL = "http://localhost:11434",
          ANTHROPIC_API_KEY = "",
          ANTHROPIC_AUTH_TOKEN = "ollama",
        }
        expected[key] = nil
        local overrides = env.prepare_env()
        assert.is_nil(overrides[key])
        assert.are.same(expected, overrides)
        assert.are.same(parent, snapshot())
      end)
    end
  end

  it("Given cached Claude env, When a full command is set, Then all job defaults are bypassed", function()
    vim.env.CLAUDE_MODEL = "local-model"
    vim.env.CLAUDE_CODE_TRACKING_ENABLED = "true"
    local env = load_env("claude")
    assert.are.equal("ollama", env.prepare_env().ANTHROPIC_AUTH_TOKEN)
    vim.env.CLAUDE_COMMAND = "claude-wrapper --custom"
    local parent = snapshot()
    local first = env.prepare_env()
    assert.are.same({}, first)
    first.MARKER = "only-first"
    assert.are.same({}, env.prepare_env())
    assert.are.equal("claude-wrapper --custom", env.command())
    assert.are.same(parent, snapshot())
  end)

  it(
    "Given parent env, When one real child gets overrides, Then it inherits siblings, keeps an empty value and leaves later jobs unchanged",
    function()
      vim.env.HD_ENV_INHERITED = "parent-marker"
      vim.env.HD_ENV_LOCAL = "parent-local"
      vim.env.HD_ENV_EMPTY = "parent-empty"
      local parent = snapshot()

      local function child(overrides)
        local output
        local job = vim.fn.jobstart({
          "/bin/sh",
          "-c",
          [[printf '%s\n' "$HD_ENV_INHERITED" "$HD_ENV_LOCAL" "${HD_ENV_EMPTY-unset}" "${HD_ENV_EMPTY+set}"]],
        }, {
          env = overrides,
          stdout_buffered = true,
          on_stdout = function(_, data)
            output = data
          end,
        })
        assert.is_true(job > 0, "jobstart must launch a real child")
        local code = vim.fn.jobwait({ job }, 5000)[1]
        if code == -1 then
          vim.fn.jobstop(job)
        end
        assert.are.equal(0, code)
        return output
      end

      assert.are.same(
        { "parent-marker", "job-local", "", "set", "" },
        child({
          HD_ENV_LOCAL = "job-local",
          HD_ENV_EMPTY = "",
        })
      )
      assert.are.same(parent, snapshot())
      assert.are.same({ "parent-marker", "parent-local", "parent-empty", "set", "" }, child())
      assert.are.same(parent, snapshot())
    end
  )
end)
