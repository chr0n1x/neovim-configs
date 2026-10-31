-- Per-harness command selection (Task 7). The strongest form of the A1 assertion: for EVERY
-- harness, when it is active its float must resolve to that harness's OWN env command - never
-- another harness's (the original A1 bug was NVIM_LLM_HARNESS=maki starting claude).
--
-- Under Task 7 there is no global terminal_cmd to re-point: term.lua resolves each harness's
-- command from its env module at open time. We switch to each harness in turn (switch().switch is
-- the same code path <leader>cl drives) and assert the active harness's float would spawn ITS OWN
-- command - catching a regression where, say, maki's env returns "maki" but the open path still
-- resolves claude's command.

local helper = require("tests.helper")
local utils = require("harness-decorators.utils")

describe("command selection: every harness runs its own CLI", function()
  local original_harness

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to start from")
  end)

  teardown(function()
    if original_harness then
      pcall(require("harness-decorators.switch").switch, original_harness)
    end
  end)

  -- One test per discovered harness so a failure names the offending harness. The list is
  -- captured at file-load time (utils.list_harnesses just scans the directory), which is
  -- safe - it does not depend on nvim runtime state.
  for _, harness in ipairs(utils.list_harnesses()) do
    it(("resolves %s to its own env command"):format(harness), function()
      local sw = require("harness-decorators.switch")
      sw.switch(harness)

      assert.are.equal(
        harness,
        helper.active_harness(),
        ("switcher did not record %s as active (got %s)"):format(harness, tostring(helper.active_harness()))
      )

      local expected = helper.env_command(harness)
      local actual = helper.term_spawn_cmd(harness)
      assert.is_string(expected, ("%s env module returned non-string: %s"):format(harness, tostring(expected)))
      assert.are.equal(
        expected,
        actual,
        ("%s desync: its float must resolve %q, got %q (wrong CLI would run)"):format(
          harness,
          tostring(expected),
          tostring(actual)
        )
      )

      -- Guard against the specific A1 failure mode: a non-claude harness must never end up
      -- running "claude".
      if harness ~= "claude" then
        assert.is_not.truthy(
          tostring(actual):match("^claude%s") or tostring(actual) == "claude",
          ("%s resolved to claude's command: %q"):format(harness, tostring(actual))
        )
      end
    end)
  end
end)

describe("command selection: current override semantics", function()
  for _, harness in ipairs({ "claude", "copilot", "crush", "maki", "pi", "pig" }) do
    describe(harness, function()
      local h = harness:upper()
      local env_mod = "harness-decorators." .. harness .. ".env"
      local vars = {
        h .. "_COMMAND",
        h .. "_MODEL",
        "NVIM_LLM_HARNESS_" .. h .. "_PROVIDER_NAME",
        "LLAMA_DEFAULT_MODEL",
        "CLAUDE_CODE_TRACKING_ENABLED",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
      }
      local saved_env, saved_mod

      before_each(function()
        saved_env, saved_mod = {}, package.loaded[env_mod]
        for _, k in ipairs(vars) do
          saved_env[k] = os.getenv(k) or vim.NIL
          vim.env[k] = nil
        end
      end)

      after_each(function()
        for k, orig in pairs(saved_env) do
          vim.env[k] = orig ~= vim.NIL and orig or nil
        end
        package.loaded[env_mod] = saved_mod
      end)

      it("Given absent overrides, When resolving the command, Then it is the bare CLI", function()
        assert.are.equal(harness, helper.env_command(harness))
      end)

      it("Given empty overrides, When resolving the command, Then it is the bare CLI", function()
        for _, k in ipairs(vars) do
          vim.env[k] = ""
        end
        assert.are.equal(harness, helper.env_command(harness))
      end)

      it("Given a full command and competing flags, When resolving, Then only the override is used", function()
        vim.env[h .. "_COMMAND"] = harness .. " --wrapped"
        vim.env[h .. "_MODEL"] = "competing/model"
        vim.env["NVIM_LLM_HARNESS_" .. h .. "_PROVIDER_NAME"] = "competing-provider"
        vim.env.LLAMA_DEFAULT_MODEL = "competing/llama"
        assert.are.equal(harness .. " --wrapped", helper.env_command(harness))
      end)

      if harness == "pi" or harness == "pig" then
        it("Given an empty command and provider/model, When resolving, Then provider precedes model", function()
          vim.env[h .. "_COMMAND"] = ""
          vim.env["NVIM_LLM_HARNESS_" .. h .. "_PROVIDER_NAME"] = "local-provider"
          vim.env.LLAMA_DEFAULT_MODEL = "local/model"
          vim.env[h .. "_MODEL"] = "ignored/model"
          assert.are.equal(harness .. " --provider local-provider --model local/model", helper.env_command(harness))
        end)
      else
        it("Given an empty command and a model, When resolving, Then only supported model flags appear", function()
          vim.env[h .. "_COMMAND"] = ""
          vim.env[h .. "_MODEL"] = "local/model"
          local flag = ({ claude = " --model ", maki = " -m " })[harness]
          assert.are.equal(harness .. (flag and flag .. "local/model" or ""), helper.env_command(harness))
        end)
      end
    end)
  end
end)
