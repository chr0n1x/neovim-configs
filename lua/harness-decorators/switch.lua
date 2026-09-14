-- Runtime harness switcher: lets <leader>cl swap the backing AI CLI (claude /
-- copilot / maki / ...) without restarting Neovim. Available harnesses are
-- discovered by listing sibling directories of this file that expose both an
-- env.lua (terminal command) and a keymaps.lua (per-harness <leader>c* keys) -
-- exactly the shape used by lua/harness-decorators/<harness>/.
--
-- Switching does four things:
--   1. Backgrounds the outgoing harness's floating terminal (config-hides it, keeping its
--      PTY alive so it keeps executing) and records the buffer for later resume - Option A.
--   2. Points claudecode.nvim's terminal module at the new harness's command.
--   3. Foregrounds the incoming harness: if it was previously backgrounded, re-shows its
--      SAME live process; otherwise leaves it closed until the first <leader>c press opens it.
--   4. Rebinds the consolidated <leader>c* keymaps to the new harness's keymaps.lua so
--      bindings like <leader>cr/<leader>cm (which differ, or don't exist, per harness) match
--      whatever is now active.
local M = {}

local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")
local title = require("harness-decorators.title")
local park = require("harness-decorators.park")
local agent_display = require("harness-decorators.agent-display")

local current_harness = nil

-- Work-status dot glyphs for the picker rows. Every harness that has been initialized (has a live
-- terminal buffer) shows one before its name, colored by its work status - the same three states and
-- highlight groups the lualine agent overview uses (see agent-display). A never-opened harness shows
-- no dot. These are plain {glyph, group} pairs (not hl markup) because telescope entry highlights use
-- named groups via display() ranges, not %#...#%* sequences.
local STATUS_DOTS = {
  working = { glyph = "● ", group = agent_display.HL_WORKING }, -- blue, pulsing in the statusline
  idle = { glyph = "✓ ", group = agent_display.HL_IDLE }, -- green checkmark (done/idle)
  unknown = { glyph = "○ ", group = agent_display.HL_UNKNOWN }, -- hollow ring
}

---The work-status dot for a harness, or nil when it has no live terminal (never opened / stopped).
---@param name string harness name
---@param bufs table<string, number> harness -> live terminal buffer map
---@return {glyph: string, group: string}?
local function status_dot(name, bufs)
  if bufs[name] == nil then
    return nil
  end
  local ok, state = pcall(require, "harness-decorators.agent-state")
  if not ok or type(state.poll) ~= "function" then
    return nil
  end
  local r = state.poll(name)
  if not r then
    return nil
  end
  return STATUS_DOTS[r.status] or STATUS_DOTS.unknown
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

---Kill the running floating terminal so the next open spawns a fresh process
---with the newly configured harness command. Force-deleting the terminal buffer
---makes the CLI process exit with a non-zero/-1 status (it's killed, not exited
---cleanly), which trips claudecode's snacks provider TermClose handler and logs
---a scary "Claude exited with code -1" error - expected and harmless here since
---we're the ones killing it, so silence claudecode's logger.error for the
---duration of the kill (restored on the next tick, after TermClose has fired).
-- REMOVED (Option A): switch.lua no longer kills the terminal on a harness swap.
-- The old process is backgrounded instead - park.park() config-hides its float
-- (keeping the PTY alive so it keeps executing) and records the buffer for later
-- resume. See docs/multi-agent-prd.md. Kept as a comment block so the reason the
-- "Claude exited with code -1" logger suppression below no longer exists is clear.

---Record initial state for the harness ai-harness.lua starts with. The keymaps
---for this first harness are registered by ai-harness.lua's config (via
---harness-decorators.keymaps), so this remembers what's active for later switches/teardown AND
---seeds the unified park table: the startup harness is selected=true (buff_nr=nil until its first
---<leader>c opens it). Without this, a fresh nvim would have no selected entry and <leader>c would
---do nothing.
---@param harness string
function M.init(harness)
  current_harness = harness
  park.set_selected(harness)
end

---Swap the backing CLI: background the current floating terminal (Option A), point
---claudecode.nvim's terminal command at the new harness's CLI, foreground any parked terminal for
---the new harness, and rebind <leader>c* to the new harness's keymaps.
---@param new_harness string
function M.switch(new_harness)
  if new_harness == current_harness then
    return
  end
  if not vim.tbl_contains(utils.list_harnesses(), new_harness) then
    vim.notify("harness: unknown harness " .. tostring(new_harness), vim.log.levels.ERROR)
    return
  end

  -- Remember the outgoing harness before we overwrite current_harness; the background/foreground
  -- notify at the end reports it by name.
  local previous_harness = current_harness

  ensure_plugin_loaded()
  -- Background the outgoing harness instead of killing it: hide ITS OWN float (PTY stays alive, so
  -- it keeps executing) and record it for resume. If focus is in the terminal window, hiding it makes
  -- nvim re-parent focus to another window and WinLeave fires - capture would record that random
  -- window as the restore target, so suppress for the tick (same reason the old kill path needed it).
  pcall(function()
    require("harness-decorators.focus").suppress_next_leave()
  end)
  local backgrounded = current_harness ~= nil and park.park(current_harness)

  -- maki disables auto_start (no @ mention server); everything else wants it. This only toggles the
  -- websocket server - it has no effect on the floating terminal, which term.lua now owns directly.
  pcall(function()
    require("claudecode").stop()
  end)
  if new_harness ~= "maki" then
    pcall(function()
      require("claudecode").start(false)
    end)
  end

  -- Re-point the harness identity. The spawn command is NOT re-pointed on any global anymore: term.lua
  -- resolves each harness's command from its env module at open time, so there is no claudecode
  -- terminal_cmd / snacks_win_opts.title to update here (that was the shared-handle path). We only
  -- refresh the env cache and the NVIM_LLM_HARNESS var the watcher/adapter layer reads.
  package.loaded["harness-decorators." .. new_harness .. ".env"] = nil
  local command = require("harness-decorators." .. new_harness .. ".env")
  vim.fn.setenv("NVIM_LLM_HARNESS", new_harness)

  -- Mark the incoming harness selected in the unified table now that it is active. This makes it the
  -- target of the next <leader>c (park.show_selected). If it was previously backgrounded, its float is
  -- already recorded so show_selected will resume the SAME live process; if not, its entry has no
  -- instance yet and the first <leader>c spawns it fresh. We do NOT auto-open here: opening on every
  -- switch surprised the user and corrupted window state, so a fresh terminal is still opened by the
  -- first <leader>c press (pre-Option-A behavior).
  park.set_selected(new_harness)

  keymaps.clear()
  keymaps.apply(keymaps.build(new_harness))
  current_harness = new_harness

  -- Re-point the JSONL watcher at the new (now-active) harness: stop the old backend (it's
  -- still subscribed to the OLD harness's sessions dir), clear all pinned/session state (so
  -- edit-jump can't keep following the previous harness's files), then restart against the new
  -- harness's sessions dir. This is what makes the watcher follow ONLY the active harness under
  -- Option A: a backgrounded (parked) harness is intentionally NOT followed - its process keeps
  -- running but produces no edit-jumps/notifications until it is foregrounded again, at which
  -- point this same re-point runs for it. If no terminal has opened yet there is no watcher
  -- running; start() spawns it, which is fine - the first <leader>c press finds it already up.
  pcall(function()
    local watcher = require("harness-decorators.watcher")
    watcher.stop()
    watcher.set_harness(new_harness)
    watcher.start()
  end)

  -- Report background/foreground accurately: if the outgoing harness had a live terminal we
  -- backgrounded it (its process keeps running); otherwise there was nothing to park, so this is
  -- just a plain switch. `backgrounded` was captured at park time above.
  if backgrounded then
    vim.notify(
      "harness: backgrounded " .. previous_harness .. ", foregrounded " .. new_harness .. " (" .. command .. ")",
      vim.log.levels.INFO
    )
  else
    vim.notify("harness: switched to " .. new_harness .. " (" .. command .. ")", vim.log.levels.INFO)
  end
end

---Run after a harness is picked from the <leader>cl picker: open the newly-selected harness's
---terminal so picking is a one-keystroke "switch AND show" (previously it only switched and left
---you to press <leader>c). Delegates to park.show_selected, which re-shows the SAME live process if
---the harness was already running, or spawns fresh otherwise. Exposed on M so tests/switch_spec.lua
---can drive it without opening a telescope picker.
function M.after_pick()
  park.show_selected()
end

---Telescope picker over available harness dirs; selecting one calls M.switch.
---Map each harness to the buffer number holding its terminal output, for the picker preview.
---Built entirely from the unified park table (Task 6), which now tracks BOTH the selected (active)
---and backgrounded (parked) terminals - so no separate claudecode-handle branch is needed. A
---harness that was never opened (no buffer) or whose process already exited is absent. This is what
---lets the preview pane show "what each one is doing". Exposed on M so tests/picker_spec.lua can
---drive it without opening a telescope picker.
---@return table<string, number> harness_to_bufnr
function M.collect_terminal_bufs()
  local map = {}
  for _, e in ipairs(park.list()) do
    map[e.harness] = e.buff_nr
  end
  return map
end

---Build a telescope entry for one harness row: an optional work-status dot (for initialized
--harnesses) followed by the harness name in its HarnessTitle<Name> group. The dot and the name are
--highlighted independently so the selected-row dimming (TelescopeSelection -> Visual, no fg) leaves
--BOTH colored. Uninstalled harnesses render dimmed with a "(not installed)" suffix. Exposed on M so
--tests/picker_spec.lua can drive it headless without opening telescope UI.
---@param name string harness name
---@param active? string kept for positional API compatibility; unused now that the status dot subsumes it
---@param bufs table<string, number> harness -> live terminal buffer map (from collect_terminal_bufs)
---@param installed? boolean whether the harness CLI is on PATH (default true)
---@return table entry { value, ordinal, display }
function M.make_entry(name, _active, bufs, installed)
  if installed == nil then
    installed = true
  end
  -- Work-status dot for initialized (live-buffer) harnesses: blue pulse / green / hollow ring before
  -- the name. A never-opened or uninstalled harness shows no dot. The `active` arg is kept for API
  -- compatibility but no longer drives a separate glyph - the status dot subsumes it.
  local dot = (installed and bufs[name] ~= nil) and status_dot(name, bufs) or nil
  local prefix = dot and dot.glyph or ""
  local suffix = installed and "" or "  (not installed)"
  local text = prefix .. name .. suffix
  local name_group = title.define(name)
  return {
    value = name,
    ordinal = name,
    display = function()
      -- No name group (unknown harness): plain text, no highlight ranges.
      if not name_group then
        return text
      end
      local ranges = { { { #prefix, #prefix + #name }, name_group } }
      if dot then
        table.insert(ranges, 1, { { 0, #prefix }, dot.group })
      end
      -- Dim the "(not installed)" suffix with a dedicated group.
      if not installed then
        local suffix_start = #prefix + #name
        table.insert(ranges, { { suffix_start, #text }, "HarnessPickerNotInstalled" })
      end
      return text, ranges
    end,
  }
end

---Build the two-line header for a preview pane: a label line (`name  (status)`) padded to `width`
---columns, and a separator line of `─` repeated `width` times. If the label is longer than `width`,
---it is truncated. Falls back to a default width of 40 when `width` is nil or non-positive.
---Exposed on M so tests/picker_spec.lua can drive it without opening telescope UI.
---@param name string harness name
---@param status string "active" | "backgrounded" | "uninitialized"
---@param width? number preview pane width in columns
---@return string header_line
---@return string separator_line
function M.preview_header(name, status, width)
  local label = name .. "  (" .. status .. ")"
  local w = (type(width) == "number" and width > 0) and math.floor(width) or 40
  if #label >= w then
    return label:sub(1, w), string.rep("─", w)
  end
  return label .. string.rep(" ", w - #label), string.rep("─", w)
end

---Telescope buffer previewer for the harness picker: renders a header plus the raw terminal
---output of the selected harness, colorizing error/warn/success tokens and auto-refreshing on a
---~500ms timer while it runs. Adapted from util/procs.lua's make_previewer (same render shape,
---colorize patterns, and refresh cadence) but resolves the buffer by harness name via
---collect_terminal_bufs() instead of a procs-registered process name.
---@param bufs table<string, number> harness -> live terminal buffer map (from collect_terminal_bufs)
---@param installed_set? table<string, boolean> harness name -> true if CLI is on PATH
---@return table previewer
local function make_harness_previewer(bufs, installed_set)
  local previewers = require("telescope.previewers")
  local active_timer = nil

  local function stop_timer()
    if active_timer then
      pcall(function()
        active_timer:stop()
        active_timer:close()
      end)
      active_timer = nil
    end
  end

  local match_ids = {}
  local function colorize(winid)
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end
    for _, id in ipairs(match_ids) do
      pcall(vim.fn.matchdelete, id, winid)
    end
    match_ids = {}
    local patterns = {
      { "ErrorMsg", [[\c\<\(error\|fatal\|fail\(ed\)\?\|panic\|denied\|refused\|exception\)\>]] },
      { "WarningMsg", [[\c\<warn\(ing\)\?\>]] },
      { "DiagnosticOk", [[\c\<\(ok\|pass\(ed\)\?\|success\(ful\)\?\|done\|complete\(d\)\?\|ready\)\>]] },
      { "Comment", [[\c\<\(debug\|info\|trace\)\>]] },
    }
    for _, p in ipairs(patterns) do
      local ok, id = pcall(vim.fn.matchadd, p[1], p[2], 10, -1, { window = winid })
      if ok then
        match_ids[#match_ids + 1] = id
      end
    end
  end

  local function render(bufnr, winid, entry)
    if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local name = entry.value
    local lines = {}
    local term_buf = bufs[name]
    local has_live = term_buf ~= nil and vim.api.nvim_buf_is_valid(term_buf)
    local is_installed = installed_set == nil or installed_set[name] ~= false
    local status
    if not is_installed then
      status = "not installed"
    elseif not has_live then
      status = "uninitialized"
    elseif name == current_harness then
      status = "active"
    else
      status = "backgrounded"
    end
    local win_width = 0
    if vim.api.nvim_win_is_valid(winid) then
      win_width = pcall(vim.api.nvim_win_get_width, winid) and vim.api.nvim_win_get_width(winid) or 0
    end
    local header_line, separator_line = M.preview_header(name, status, win_width)
    table.insert(lines, header_line)
    table.insert(lines, separator_line)
    if not is_installed then
      table.insert(lines, "(not installed)")
    elseif has_live then
      vim.list_extend(lines, vim.api.nvim_buf_get_lines(term_buf, 0, -1, false))
    else
      table.insert(lines, "(not started)")
    end
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_set_cursor, winid, { #lines, 0 })
      colorize(winid)
    end
  end

  return previewers.new_buffer_previewer({
    title = "output",
    define_preview = function(self, entry)
      stop_timer()
      render(self.state.bufnr, self.state.winid, entry)
      active_timer = vim.uv.new_timer()
      active_timer:start(
        500,
        500,
        vim.schedule_wrap(function()
          render(self.state.bufnr, self.state.winid, entry)
        end)
      )
    end,
    teardown = function()
      stop_timer()
    end,
  })
end

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

  local agent_state = require("harness-decorators.agent-state")
  local harnesses = agent_state.harnesses()
  -- Terminal buffers to preview (active + parked). Captured once at picker-open; the previewer's
  -- refresh timer re-reads these buffers live, so a running harness's output updates in place.
  local bufs = M.collect_terminal_bufs()
  -- Set of installed harness names, used by both the previewer (status line) and the Enter guard.
  local installed_set = {}
  for _, h in ipairs(harnesses) do
    if h.installed then
      installed_set[h.name] = true
    end
  end

  pickers
    .new({}, {
      -- Titles (Task 9): the prompt is a plain "search", the results list is "Harnesses", and the
      -- preview pane is "Preview". The per-harness name already appears as the first line INSIDE the
      -- preview buffer (render below), so a static title is enough - telescope titles are set once at
      -- picker creation, not per entry.
      prompt_title = "search",
      results_title = "Harnesses",
      preview_title = "Preview",
      -- Horizontal layout (Task 9): the prompt + results list stacked in one column on the LEFT, the
      -- colored preview pane on the RIGHT. The vertical strategy can't put the preview beside the
      -- list, and telescope has no multi-column results grid - horizontal is the only strategy that
      -- splits left (prompt+results) vs right (preview). prompt_position="top" keeps the prompt above
      -- the list in that left column; preview_width/preview_cutoff are the valid keys for this
      -- strategy (preview_height belongs to vertical and errors here).
      layout_strategy = "horizontal",
      layout_config = {
        prompt_position = "bottom",
        -- preview_width is a fraction of the TOTAL layout width; the left column (prompt+results) gets
        -- the rest (layout_strategies.lua: results.width = width - preview.width - spacing). The harness
        -- list is short (a handful of short names), so give most of the width to the preview and keep the
        -- left column thin. 0.5 was an even split, which wasted space on a tiny list.
        preview_width = 0.85,
        preview_cutoff = 12,
        width = 0.8,
        height = 0.8,
      },
      finder = finders.new_table({
        results = harnesses,
        entry_maker = function(h)
          -- See M.make_entry: a colored state glyph (active / parked / idle) plus the name in its
          -- HarnessTitle<Name> group. Uninstalled harnesses render dimmed with a "(not installed)"
          -- suffix so the user can see them but knows they're inert.
          return M.make_entry(h.name, current_harness, bufs, h.installed)
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = make_harness_previewer(bufs, installed_set),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          if not selection or not selection.value then
            return
          end
          -- Uninstalled harnesses are inert: no switch, no open. The row is dimmed and the
          -- "(not installed)" suffix signals this; Enter shows a notification and does nothing.
          if not installed_set[selection.value] then
            vim.notify("harness " .. selection.value .. " is not installed", vim.log.levels.INFO)
            return
          end
          actions.close(prompt_bufnr)
          M.switch(selection.value)
          -- After switching, open the newly-selected harness's terminal so the picker is a one-keystroke
          -- "switch AND show" - previously it only switched and left you to press <leader>c. Re-shows the
          -- SAME live process if the harness was already running (park.show_selected -> term.open).
          M.after_pick()
        end)
        return true
      end,
    })
    :find()
end

return M
