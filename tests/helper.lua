-- Shared helpers for the integration specs.
--
-- The specs run INSIDE a headless nvim that has already loaded the full real config:
-- `tests/ci.sh` starts `nvim --headless -c "luafile tests/runner.lua"`, and runner.lua waits
-- until the harness-decorators modules load before handing control to busted. By the time any
-- spec body runs, every plugin lazy.nvim loads at startup is loaded and the harness layer has
-- executed its real startup path (a plugin lazy-loaded on a filetype or event loads only when
-- that fires). Specs therefore drive the live in-process nvim directly (vim.keymap, vim.cmd,
-- vim.api) - no child process, no RPC, no READY polling needed.
--
-- All execution happens inside the test container. The host contributes only the
-- mounted config source (XDG_CONFIG_HOME=/nvim-config) and the plugin cache
-- (/root/.local/share/nvim). Nothing here reads or writes anywhere else on the host.

local M = {}

---Wait until a terminal-buftype window exists and is visible, or timeout. In headless
-- mode snacks' float open can hang before its terminal state is recorded, but the terminal
-- buffer/window IS created - so we detect by scanning for a terminal buftype window
-- rather than trusting the recorded terminal state. Returns the terminal window id (or nil).
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

---Create a scratch buffer named after a temp path (no window is opened) so there is a real,
-- non-terminal "originating" buffer to return focus to. Returns the buffer number. Uses
-- nvim_create_buf and nvim_buf_set_name rather than `:enew <path>` to avoid Ex-argument escaping
-- issues with absolute temp paths in headless mode.
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

---Evaluate a harness's current command without reloading its env module or preparing job env.
---@param harness string
---@return string
function M.env_command(harness)
  return require("harness-decorators." .. harness .. ".env").command()
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

---The command our per-harness terminal owner (term.lua) will spawn for `harness`, resolved at call
-- time from its env module (plus optional args). Each harness's float resolves its own command
-- when it opens (there is no shared terminal command). Returns nil if the harness has no env
-- command.
---@param harness string
---@param opts? { args?: string }
---@return string? cmd
function M.term_spawn_cmd(harness, opts)
  local ok, term = pcall(require, "harness-decorators.term")
  if not ok then
    return nil
  end
  local ok_env, env = pcall(require, "harness-decorators." .. harness .. ".env")
  if not ok_env or type(env) ~= "table" or type(env.command) ~= "function" then
    return nil
  end
  local cmd = env.command()
  if opts and opts.args then
    cmd = cmd .. " " .. opts.args
  end
  return cmd
end

---Collect any Lua errors logged during the session so a red spec can surface them.
-- Reads the message history and filters for lines that look like Lua tracebacks.
---@return string
function M.lua_errors()
  local msgs = vim.api.nvim_exec2("messages", { output = true }).output or ""
  return msgs:match("Lua:%s*([^\n]+)") or ""
end

return M
