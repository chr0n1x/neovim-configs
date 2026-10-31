-- Unit spec for pig's env module: the spawn command built from PIG_COMMAND /
-- NVIM_LLM_HARNESS_PIG_PROVIDER_NAME / LLAMA_DEFAULT_MODEL. Same shape as pi_env_spec: each case
-- forces env state, calls command() via helper.env_command, and teardown restores it.

local helper = require("tests.helper")

local CMD_VAR = "PIG_COMMAND"
local PROVIDER_VAR = "NVIM_LLM_HARNESS_PIG_PROVIDER_NAME"
local MODEL_VAR = "LLAMA_DEFAULT_MODEL"

describe("pig env command (flag threading from env)", function()
  local saved = {}

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
      saved[k] = vim.fn.getenv(k)
    end
  end)

  teardown(function()
    for k, orig in pairs(saved) do
      if orig == "" or orig == vim.NIL then
        vim.cmd("unlet! $" .. k)
      else
        vim.fn.setenv(k, orig)
      end
    end
  end)

  it("Given no vars set, When pig launches, Then the command is bare `pig`", function()
    set_vars(nil, nil, nil)
    assert.are.equal("pig", helper.env_command("pig"))
  end)

  it("Given provider and model vars, When pig launches, Then both flags are appended, provider first", function()
    set_vars(nil, "llama-cpp", "some/model")
    assert.are.equal("pig --provider llama-cpp --model some/model", helper.env_command("pig"))
  end)

  it("Given the pi provider var only, When pig launches, Then pig ignores it", function()
    set_vars(nil, nil, nil)
    vim.fn.setenv("NVIM_LLM_HARNESS_PI_PROVIDER_NAME", "pi-only")
    local cmd = helper.env_command("pig")
    vim.cmd("unlet! $NVIM_LLM_HARNESS_PI_PROVIDER_NAME")
    assert.are.equal("pig", cmd)
  end)

  it("Given PIG_COMMAND, When pig launches, Then it overrides everything", function()
    set_vars("pig --no-tools", "llama-cpp", "some/model")
    assert.are.equal("pig --no-tools", helper.env_command("pig"))
  end)
end)
