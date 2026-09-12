-- Shared helpers for the integration specs.
--
-- The specs run INSIDE a headless nvim that has already loaded the full real config
-- (option A): `tests/ci.sh` starts `nvim --headless -c "luafile tests/runner.lua"`,
-- and runner.lua waits for LazyDone before handing control to busted. By the time any
-- spec body runs, every plugin is loaded and the harness layer has executed its real
-- startup path. Specs therefore drive the live in-process nvim directly (vim.keymap,
-- vim.cmd, vim.api) - no child process, no RPC, no READY polling needed.
--
-- All execution happens inside the test container. The host contributes only the
-- mounted config source (XDG_CONFIG_HOME=/nvim-config) and the plugin cache
-- (/root/.local/share/nvim). Nothing here reads or writes anywhere else on the host.

local M = {}

-- Capture the pristine startup terminal command at require-time (before any spec mutates
-- it). Specs that override terminal_cmd (focus_spec's stub) restore to this in teardown so
-- they leave no trace for later specs - especially startup_spec, which asserts the true
-- startup value. Requiring helper.lua happens before any spec body runs, so this records
-- the genuine post-startup state.
M.pristine_terminal_cmd = (function()
  local ok, term = pcall(require, "claudecode.terminal")
  if not ok or not term.defaults then
    return nil
  end
  return term.defaults.terminal_cmd
end)()

---Wait until a terminal-buftype window exists and is visible, or timeout. In headless
-- mode snacks' float open can hang before recording cc.state.terminal, but the terminal
-- buffer/window IS created - so we detect by scanning for a terminal buftype window
-- rather than trusting state.terminal. Returns the terminal window id (or nil).
---@param timeout_ms number|nil
---@return number? term_win
function M.wait_for_terminal(timeout_ms)
  timeout_ms = timeout_ms or 10000
  local deadline = vim.uv.now() + timeout_ms
  while vim.uv.now() < deadline do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_get_option(b, "buftype") == "terminal" then
          local cfg = vim.api.nvim_win_get_config(w)
          if not cfg.hide then
            return w
          end
        end
      end
    end
    vim.wait(50)
  end
  return nil
end

---Find the window currently showing a terminal buffer, or nil.
---@return number? win_id
function M.terminal_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_get_option(b, "buftype") == "terminal" then
        return w
      end
    end
  end
  return nil
end

---Find the window currently showing a non-terminal buffer, or nil. Used to record
-- "where we were before opening the terminal" for focus assertions.
---@return number? win_id
function M.current_non_terminal_win()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_buf_get_option(buf, "buftype") ~= "terminal" then
    return win
  end
  -- fall back to the first non-terminal window in the tab
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_option(b, "buftype") ~= "terminal" then
      return w
    end
  end
  return nil
end

---The buffer currently shown in the focused window.
---@return number bufnr
function M.current_buf()
  return vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
end

---Open a scratch file buffer (in a fresh window) so there is a real, non-terminal
-- "originating" buffer to return focus to. Returns the buffer number. Uses nvim_open_buf
-- on an empty buffer rather than `:enew <path>` to avoid Ex-argument escaping issues with
-- absolute temp paths in headless mode.
---@param name string|nil filename under the temp dir
---@return number bufnr
function M.open_scratch(name)
  local path = vim.fn.tempname() .. (name or "-scratch.txt")
  -- Create a fresh empty buffer and point it at the scratch path. No file is written;
  -- we only need a real, non-terminal buffer to serve as the focus origin.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, path)
  return buf
end

---The command string a harness's env module resolves to. This is the ground truth the
-- A1 assertion compares against: after startup, claudecode.state.config.terminal_cmd
-- must equal this for the active harness.
---@param harness string
---@return string
function M.env_command(harness)
  package.loaded["harness-decorators." .. harness .. ".env"] = nil
  return require("harness-decorators." .. harness .. ".env")
end

---The currently-active harness name per the switcher module.
---@return string?
function M.active_harness()
  local ok, sw = pcall(require, "harness-decorators.switch")
  if not ok then
    return nil
  end
  return sw.current()
end

---The terminal command claudecode.nvim will actually run. This is the value that
-- reaches the spawned process: it lives in the terminal module's `defaults` table,
-- which setup() populates from config.terminal_cmd. (state.config.terminal_cmd is the
-- source; defaults.terminal_cmd is what the PTY uses.) Checking defaults catches both
-- a nil-at-startup desync (A1) and a failed re-point after a harness swap.
---@return string?
function M.terminal_cmd()
  local ok, term = pcall(require, "claudecode.terminal")
  if not ok or not term.defaults then
    return nil
  end
  return term.defaults.terminal_cmd
end

---Collect any Lua errors logged during the session so a red spec can surface them.
-- Reads the message history and filters for lines that look like Lua tracebacks.
---@return string
function M.lua_errors()
  local msgs = vim.api.nvim_exec2("messages", { output = true }).output or ""
  return msgs:match("Lua:%s*([^\n]+)") or ""
end

return M
