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

local keymaps = require("harness-decorators.keymaps")
local title = require("harness-decorators.title")

local current_harness = nil

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

---Record initial state for the harness ai-harness.lua starts with. The keymaps
---for this first harness are registered by ai-harness.lua's config (via
---harness-decorators.keymaps), so this just remembers what's active for later
---switches/teardown.
---@param harness string
function M.init(harness)
  current_harness = harness
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
  if not vim.tbl_contains(keymaps.list_harnesses(), new_harness) then
    vim.notify("harness: unknown harness " .. tostring(new_harness), vim.log.levels.ERROR)
    return
  end

  ensure_plugin_loaded()
  -- kill_terminal force-deletes the terminal buffer; if focus is in it, nvim
  -- re-parents the window to the next visible buffer and WinLeave fires - capture
  -- would record that random window as the restore target. Suppress for the tick.
  pcall(function()
    require("harness-decorators.focus").suppress_next_leave()
  end)
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
    -- snacks_win_opts.title was built from the harness at config-load time;
    -- re-point it so the next terminal open shows the new harness's name and color.
    local win_opts = claudecode.state.config.snacks_win_opts
      or claudecode.state.config.terminal and claudecode.state.config.terminal.snacks_win_opts
    if type(win_opts) == "table" then
      win_opts.title = title.title(new_harness)
    end
  end
  -- nil user_term_config leaves previously configured terminal opts (snacks
  -- window layout, keymaps, etc.) untouched; only terminal_cmd/env change.
  require("claudecode.terminal").setup(nil, command, {})

  keymaps.clear()
  keymaps.apply(keymaps.build(new_harness))
  current_harness = new_harness

  -- Re-point the JSONL watcher at the new harness: stop the old backend (it's
  -- still subscribed to the OLD harness's sessions dir), clear all pinned/session
  -- state (so edit-jump can't keep following the previous harness's files), then
  -- restart against the new harness's sessions dir. If no terminal has opened yet
  -- there is no watcher running; start() spawns it, which is fine - the first
  -- <leader>c press will find it already up and skip its own start.
  pcall(function()
    local watcher = require("harness-decorators.watcher")
    watcher.stop()
    watcher.set_harness(new_harness)
    watcher.start()
  end)

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

  local harnesses = keymaps.list_harnesses()
  -- Size the window to the list so nothing scrolls off, capped so a large set
  -- doesn't fill the screen (past the cap it scrolls). In telescope's horizontal
  -- layout with no previewer and prompt at top, the visible result rows are
  -- (height - 5): 1 prompt line + 4 border/spacing lines of chrome (verified in
  -- telescope/pickers/layout_strategies.lua). So height = <rows to show> + 5.
  local visible_rows = math.max(1, math.min(#harnesses, 10))
  local height = visible_rows + 5

  pickers
    .new({}, {
      prompt_title = "AI Harness (current: " .. (current_harness or "?") .. ")",
      -- small fixed-size window; the harness list is short, no need for the
      -- default near-fullscreen layout. The horizontal strategy's valid keys
      -- are height/width (fractions of the window) and prompt_position -
      -- results_height only exists on the vertical strategy.
      layout_strategy = "horizontal",
      layout_config = {
        prompt_position = "top",
        preview_width = 0,
        height = height,
        width = 40,
      },
      finder = finders.new_table({
        results = harnesses,
        entry_maker = function(name)
          local marker = name == current_harness and "* " or "  "
          local text = marker .. name
          -- Color the harness name with its shared HarnessTitle<Name> group (the
          -- same color used for the floating-terminal title). A function display
          -- returns (text, highlights); highlight columns are 0-indexed byte
          -- offsets into `text`, so the name starts right after the 2-char marker.
          local group = title.define(name)
          return {
            value = name,
            ordinal = name,
            display = function()
              if not group then
                return text
              end
              return text, { { { #marker, #marker + #name }, group } }
            end,
          }
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
