-- Runtime harness switcher: lets <leader>cl swap the backing AI CLI (claude /
-- copilot / maki / ...) without restarting Neovim. Available harnesses are
-- discovered by listing sibling directories of this file that expose both an
-- env.lua (terminal command) and a keymaps.lua (per-harness <leader>c* keys) -
-- exactly the shape used by lua/harness-decorators/<harness>/.
--
-- Switching does three things:
--   1. Kills the running floating terminal (and, for harnesses that use it,
--      the claudecode websocket server) so the next open spawns a fresh
--      process instead of reusing the old one.
--   2. Points claudecode.nvim's terminal module at the new harness's command.
--   3. Rebinds the consolidated <leader>c* keymaps to the new harness's
--      keymaps.lua so bindings like <leader>cr/<leader>cm (which differ, or
--      don't exist, per harness) match whatever is now active.
local M = {}

local this_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local FT_AUGROUP = "AiHarnessFtKeys"

local current_harness = nil
local current_specs = {} -- last-applied keymaps.lua spec list, for teardown on switch

---List sibling directories that look like a harness (env.lua + keymaps.lua).
---@return string[]
function M.list_harnesses()
  local found = {}
  local fd = vim.uv.fs_scandir(this_dir)
  if fd then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if ftype == "directory" then
        local dir = this_dir .. "/" .. name
        if vim.uv.fs_stat(dir .. "/env.lua") and vim.uv.fs_stat(dir .. "/keymaps.lua") then
          table.insert(found, name)
        end
      end
    end
  end
  table.sort(found)
  return found
end

---@return string? the currently active harness name
function M.current()
  return current_harness
end

---Ensure claudecode.nvim (a lazy-loaded plugin) is actually loaded before we
---poke at its modules/commands - by the time M.switch runs the plugin should
---already be loaded (it's triggered from a key that lives in the plugin's own
---lazy.nvim `keys` spec), but this is a cheap safety net.
local function ensure_plugin_loaded()
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "claudecode.nvim" } })
  end
end

---rhs from keymaps.lua is either a Lua function or a string like
---"<cmd>ClaudeCode --resume<cr>" - vim.keymap.set accepts both forms
---natively, so no conversion needed; kept as a passthrough for clarity.
local function set_buffer_ft_keymap(buf, spec)
  vim.keymap.set(spec.mode or "n", spec[1], spec[2], {
    buffer = buf,
    desc = spec.desc,
    silent = true,
  })
end

---Remove whatever keymaps the previously-active harness registered.
local function clear_current_keymaps()
  for _, spec in ipairs(current_specs) do
    if not spec.ft then
      pcall(vim.keymap.del, spec.mode or "n", spec[1])
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, FT_AUGROUP)
end

---Register the given harness's <leader>c* keymaps, plus the harness-agnostic
---<leader>cl switcher itself so it always survives a switch's clear/reapply.
---@param harness string
local function apply_keymaps(harness)
  package.loaded["harness-decorators." .. harness .. ".keymaps"] = nil
  local specs = require("harness-decorators." .. harness .. ".keymaps")
  table.insert(specs, {
    "<leader>cl",
    function()
      M.pick()
    end,
    desc = "Switch AI harness",
    mode = { "n" },
  })

  local ft_group = vim.api.nvim_create_augroup(FT_AUGROUP, { clear = true })

  for _, spec in ipairs(specs) do
    if spec.ft then
      -- Buffer-local: apply immediately to already-open matching buffers,
      -- then keep applying to future ones via FileType.
      local fts = type(spec.ft) == "table" and spec.ft or { spec.ft }
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(fts, vim.bo[buf].filetype) then
          set_buffer_ft_keymap(buf, spec)
        end
      end
      vim.api.nvim_create_autocmd("FileType", {
        group = ft_group,
        pattern = spec.ft,
        callback = function(args)
          set_buffer_ft_keymap(args.buf, spec)
        end,
      })
    else
      vim.keymap.set(spec.mode or "n", spec[1], spec[2], {
        desc = spec.desc,
        silent = true,
      })
    end
  end

  current_specs = specs
end

---Kill the running floating terminal so the next open spawns a fresh process
---with the newly configured harness command. Force-deleting the terminal buffer
---makes the CLI process exit with a non-zero/-1 status (it's killed, not exited
---cleanly), which trips claudecode's snacks provider TermClose handler and logs
---a scary "Claude exited with code -1" error - expected and harmless here since
---we're the ones killing it, so silence claudecode's logger.error for the
---duration of the kill (restored on the next tick, after TermClose has fired).
local function kill_terminal()
  local ok_logger, logger = pcall(require, "claudecode.logger")
  local original_error = ok_logger and logger.error or nil
  if ok_logger then
    logger.error = function() end
  end

  pcall(function()
    require("claudecode.terminal").close()
  end)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  if ok_logger then
    vim.schedule(function()
      logger.error = original_error
    end)
  end
end

---Record initial state for the harness lazy.nvim starts with. The actual
---keymaps for this first harness are registered by lazy.nvim's own `keys`
---handling (ai-harness.lua still passes the full spec list as `keys` on the
---plugin), so this just remembers what's active for later switches/teardown.
---@param harness string
---@param specs table[] the keymaps.lua spec list currently in effect
function M.init(harness, specs)
  current_harness = harness
  current_specs = specs
end

---Swap the backing CLI: kill the current floating terminal, point
---claudecode.nvim's terminal command at the new harness's CLI, and rebind
---<leader>c* to the new harness's keymaps.
---@param new_harness string
function M.switch(new_harness)
  if new_harness == current_harness then
    vim.notify("harness: already using " .. new_harness, vim.log.levels.INFO)
    return
  end
  if not vim.tbl_contains(M.list_harnesses(), new_harness) then
    vim.notify("harness: unknown harness " .. tostring(new_harness), vim.log.levels.ERROR)
    return
  end

  ensure_plugin_loaded()
  kill_terminal()

  -- maki disables auto_start (no @ mention server); everything else wants it.
  pcall(function()
    require("claudecode").stop()
  end)
  if new_harness ~= "maki" then
    pcall(function()
      require("claudecode").start(false)
    end)
  end

  package.loaded["harness-decorators." .. new_harness .. ".env"] = nil
  local command = require("harness-decorators." .. new_harness .. ".env")
  vim.fn.setenv("NVIM_LLM_HARNESS", new_harness)

  local ok_cc, claudecode = pcall(require, "claudecode")
  if ok_cc then
    claudecode.state.config.terminal_cmd = command
  end
  -- nil user_term_config leaves previously configured terminal opts (snacks
  -- window layout, keymaps, etc.) untouched; only terminal_cmd/env change.
  require("claudecode.terminal").setup(nil, command, {})

  clear_current_keymaps()
  apply_keymaps(new_harness)
  current_harness = new_harness

  vim.notify("harness: switched to " .. new_harness .. " (" .. command .. ")", vim.log.levels.INFO)
end

---Telescope picker over available harness dirs; selecting one calls M.switch.
function M.pick()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  if not ok_pickers then
    vim.notify("harness: telescope.nvim not available", vim.log.levels.ERROR)
    return
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "AI Harness (current: " .. (current_harness or "?") .. ")",
      finder = finders.new_table({
        results = M.list_harnesses(),
        entry_maker = function(name)
          local marker = name == current_harness and "* " or "  "
          return { value = name, display = marker .. name, ordinal = name }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection and selection.value then
            M.switch(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
