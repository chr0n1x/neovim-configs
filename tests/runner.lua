-- Entry point invoked by tests/ci.sh via `nvim --headless -c "luafile tests/runner.lua"`.
--
-- The config loads normally (this file is sourced after startup, so all plugins are
-- already set up). We wait until the harness layer is loaded, then run busted IN-PROCESS
-- against the tests/ directory. Running busted inside this same nvim means the full real
-- config is live - exactly option A - and specs can call the vim API directly.
--
-- Why not `require("busted.runner")`: that wrapper parses its file list from the global
-- `arg` table via cliargs, which fights in-process invocation (it expects a real argv).
-- Instead we drive the busted.core library API directly - create a core instance, attach
-- an output handler, load the spec files with test_file_loader, subscribe to failure and
-- error events, then execute. This is the same path the CLI uses, minus the arg parsing.

local function wait_until_ready(timeout_ms)
  timeout_ms = timeout_ms or 60000
  local deadline = vim.uv.now() + timeout_ms
  while vim.uv.now() < deadline do
    local ok_cc = pcall(require, "claudecode")
    local ok_sw = pcall(require, "harness-decorators.switch")
    if ok_cc and ok_sw then
      return true
    end
    vim.wait(100) -- process events so lazy.nvim can finish loading
  end
  io.stderr:write("warning: harness modules not ready within " .. timeout_ms .. "ms\n")
  return false
end

wait_until_ready()

-- busted is installed via luarocks at /usr/local/share/lua/5.1; nvim's LuaJIT shares that
-- path. Prepend it defensively in case the container's LUA_PATH isn't inherited by nvim.
package.path = "/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;" .. package.path

local ok_core, err = pcall(require, "busted.core")
if not ok_core then
  io.stderr:write("could not load busted.core: " .. tostring(err) .. "\n")
  vim.cmd("cquit! 1")
end

-- Create the core instance, register the standard executors (file/describe/it), and
-- attach a terminal output handler so pass/fail lines print. `require "busted"(busted)`
-- is the init module that wires up busted.executors.file etc., which test_file_loader
-- needs to load each spec.
local busted = require("busted.core")()
require("busted")(busted)

-- Minimal inline reporter: print each it-block result as it completes, and collect
-- failure/error detail so a red run shows exactly what broke (not just a count). This
-- is more reliable than the terminal output handler in a headless pipe.
local function fullname(element)
  local names, parent = {}, element.parent
  while parent and (parent.name or parent.descriptor) do
    if parent.name then
      table.insert(names, 1, parent.name)
    end
    parent = parent.parent
  end
  return table.concat(names, " > ")
end
busted.subscribe({ "test", "start" }, function(element)
  io.write("  * " .. fullname(element) .. " " .. (element.name or "") .. "\n")
end)
local failures, errors = 0, 0
busted.subscribe({ "failure" }, function(element, _, message)
  failures = failures + 1
  io.write("    FAIL: " .. fullname(element) .. " " .. (element.name or "") .. "\n")
  io.write("      " .. tostring(message):gsub("\n", "\n      ") .. "\n")
end)
busted.subscribe({ "error" }, function(element, _, message)
  errors = errors + 1
  io.write("    ERROR: " .. fullname(element) .. " " .. (element.name or "") .. "\n")
  io.write("      " .. tostring(message):gsub("\n", "\n      ") .. "\n")
end)

-- Load the spec files from tests/ (non-recursive; our specs are flat). The loader factory
-- takes (busted, loaders) where loaders names the file-type modules to use ("lua" here),
-- and returns loadTestFiles(rootFiles, patterns, options).
local ok_load, load_err = pcall(function()
  local loadTestFiles = require("busted.modules.test_file_loader")(busted, { "lua" })
  loadTestFiles({ "tests" }, { "_spec%.lua$" }, { recursive = false, excludes = {} })
end)
if not ok_load then
  io.stderr:write("could not load spec files: " .. tostring(load_err) .. "\n")
  vim.cmd("cquit! 1")
end

-- Execute. runs=1, no shuffling/sorting for deterministic order. skipAll=false so one
-- failure doesn't abort the rest of the suite (busted defaults to stopping on first fail).
busted.skipAll = false
local ok_exec, exec_err = pcall(function()
  local execute = require("busted.execute")(busted)
  execute(1, { seed = 0 })
end)
if not ok_exec then
  io.stderr:write("execution error: " .. tostring(exec_err) .. "\n")
  vim.cmd("cquit! 1")
end

busted.publish({ "exit" })

local total = failures + errors
io.write(string.format("\n==> busted: %d failures, %d errors\n", failures, errors))
vim.cmd("cquit! " .. (total > 0 and 1 or 0))
