-- Unit spec for pi's env module: the spawn command built from PI_COMMAND /
-- NVIM_LLM_HARNESS_PI_PROVIDER_NAME / LLAMA_DEFAULT_MODEL. The module reads os.getenv at
-- require time and returns a bare string, so each case forces the env state, reloads the
-- module via helper.env_command (which clears package.loaded first), and teardown restores
-- whatever the environment had before - the suite must never leak these vars into other specs.

local helper = require("tests.helper")

local CMD_VAR = "PI_COMMAND"
local PROVIDER_VAR = "NVIM_LLM_HARNESS_PI_PROVIDER_NAME"
local MODEL_VAR = "LLAMA_DEFAULT_MODEL"

describe("pi env command (flag threading from env)", function()
  local saved = {}

  ---Force the three vars to the given values; nil means "unset".
  local function set_vars(cmd, provider, model)
    for _, k in ipairs({ CMD_VAR, PROVIDER_VAR, MODEL_VAR }) do
      vim.cmd("unlet! $" .. k)
    end
    if cmd ~= nil then
      vim.fn.setenv(CMD_VAR, cmd)
    end
    if provider ~= nil then
      vim.fn.setenv(PROVIDER_VAR, provider)
    end
    if model ~= nil then
      vim.fn.setenv(MODEL_VAR, model)
    end
  end

  setup(function()
    for _, k in ipairs({ CMD_VAR, PROVIDER_VAR, MODEL_VAR }) do
      saved[k] = vim.fn.getenv(k) -- "" when unset
    end
  end)

  teardown(function()
    for k, orig in pairs(saved) do
      if orig == "" then
        vim.cmd("unlet! $" .. k)
      else
        vim.fn.setenv(k, orig)
      end
    end
  end)

  it("returns bare `pi` when none of the vars are set", function()
    set_vars(nil, nil, nil)
    assert.are.equal("pi", helper.env_command("pi"))
  end)

  it("treats empty-string vars as unset", function()
    set_vars("", "", "")
    assert.are.equal("pi", helper.env_command("pi"))
  end)

  it("appends --provider when only the provider var is set", function()
    set_vars(nil, "llama-cpp", nil)
    assert.are.equal("pi --provider llama-cpp", helper.env_command("pi"))
  end)

  it("appends --model when only the model var is set", function()
    set_vars(nil, nil, "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL")
    assert.are.equal("pi --model unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL", helper.env_command("pi"))
  end)

  it("appends both flags, provider before model, when both are set", function()
    set_vars(nil, "llama-cpp", "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL")
    assert.are.equal(
      "pi --provider llama-cpp --model unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL",
      helper.env_command("pi"))
  end)

  it("honors PI_COMMAND as a full override, even when the flag vars are set", function()
    set_vars("pi --no-tools -e /tmp/ext.lua", "llama-cpp", "some/model")
    assert.are.equal("pi --no-tools -e /tmp/ext.lua", helper.env_command("pi"))
  end)
end)
