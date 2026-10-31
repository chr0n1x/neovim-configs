-- Runtime harness switcher: makes the new harness active, rebinds <leader>c*, runs the adapter's
-- on_activate, and re-points the watcher. Harnesses are sibling dirs with env.lua + keymaps.lua.
local M = {}

local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")
local title = require("harness-decorators.title")
local park = require("harness-decorators.park")
local agent_display = require("harness-decorators.agent-display")
local active = require("harness-decorators.active")

local zen_was_open = false

-- Status glyphs for picker rows (each followed by a space); same states and groups as agent-display.
local STATUS_DOTS = {
  working = { glyph = agent_display.GLYPH.working .. " ", group = agent_display.HL_WORKING },
  idle = { glyph = agent_display.GLYPH.idle .. " ", group = agent_display.HL_IDLE },
  unknown = { glyph = agent_display.GLYPH.unknown .. " ", group = agent_display.HL_UNKNOWN },
}

---The work-status dot for a harness from the statusline's last poll (agent-display), or nil when it
---has no live terminal (never opened / stopped) or has not been polled yet.
---@param name string harness name
---@param bufs table<string, number> map of harness name to live terminal buffer
---@return {glyph: string, group: string}?
local function status_dot(name, bufs)
  if bufs[name] == nil then
    return nil
  end
  local r = agent_display.status(name)
  if not r then
    return nil
  end
  return STATUS_DOTS[r.status] or STATUS_DOTS.unknown
end

---@return string the currently active harness name
function M.current()
  return active.get()
end

---Record the startup harness so the first <leader>c has a target.
---@param harness string
function M.init(harness)
  active.set(harness)
end

---Make new_harness active: keymaps, watcher. Other floats stay open.
---@param new_harness string
function M.switch(new_harness)
  if new_harness == M.current() then
    return
  end
  if not vim.tbl_contains(utils.list_harnesses(), new_harness) then
    vim.notify("harness: unknown harness " .. tostring(new_harness), vim.log.levels.ERROR)
    return
  end

  pcall(require("harness-decorators.term").expect_focus, new_harness)

  -- Focus may move during the switch; keep focus.capture from recording it.
  pcall(require("harness-decorators.focus").suppress_next_leave)
  -- zen-mode closes itself when a normal window gets focus; keep focus on the zen window while the
  -- incoming harness is shown.
  local zwin = require("util.zen").win()
  if zwin then
    pcall(vim.api.nvim_set_current_win, zwin)
  end
  -- The outgoing harness's float stays open; it is "backgrounded" in that it is no longer the
  -- active harness for keymaps and watchers.
  pcall(require("harness-decorators.term").reset_layout, new_harness)
  M.activate(new_harness)
end

---Run the adapter's optional on_activate hook (only pi defines it: symlinks its edit-following
---extension into pi's extensions dir). A failing hook does not abort the caller.
---@param harness string
---@param adapter? table Preloaded adapter when imports must finish before state changes.
function M.activate_adapter(harness, adapter)
  adapter = adapter or require("harness-decorators." .. harness)
  if type(adapter.on_activate) == "function" then
    local ok, err = pcall(adapter.on_activate)
    if not ok then
      vim.notify(harness .. ": activation hook failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

---Make new_harness the active harness: <leader>c* keymaps, adapter on_activate and the
---watcher. Focus and the floats stay where they are, so focusing a float can call this directly.
---@param new_harness string
function M.activate(new_harness)
  if new_harness == M.current() or not vim.tbl_contains(utils.list_harnesses(), new_harness) then
    return
  end

  -- Load activation dependencies before changing bindings; job env is resolved only at spawn.
  local adapter = require("harness-decorators." .. new_harness)
  require("harness-decorators.watcher")
  local specs = keymaps.build(new_harness)

  vim.fn.setenv("NVIM_LLM_HARNESS", new_harness)

  keymaps.clear()
  keymaps.apply(specs)
  local old = active.get()
  active.set(new_harness)

  M.activate_adapter(new_harness, adapter)

  -- Observers such as the watcher (it registers on load) re-point themselves.
  active.notify(new_harness, old)
end

---After a pick: start following and show the active harness.
function M.after_pick()
  -- Same first step as <leader>c: register the edit-jump autocmds and start the watcher (once per
  -- session), so a harness started from the picker follows its edits too.
  pcall(require("harness-decorators").setup_auto_follow)
  park.show_selected()
  pcall(require("harness-decorators.term").grid)
  -- Restore zen mode if it was open when the picker was invoked. The
  -- switch/show flow moves focus through non-float windows, which triggers
  -- zen-mode's WinEnter close. Re-open it around zen's last parent window,
  -- then hand focus back to the harness float.
  if zen_was_open then
    zen_was_open = false
    -- zen-mode open() runs :norm! zz which errors from terminal mode.
    -- After show_selected we are in terminal mode, so wait for the
    -- user to leave it (ModeChanged with pattern `t->*`) before reopening zen.
    local function try_open_zen()
      pcall(function()
        local view = require("zen-mode.view")
        if not view.is_open() then
          local cur = vim.api.nvim_get_current_win()
          local parent = view.parent
          if parent and vim.api.nvim_win_is_valid(parent) then
            vim.api.nvim_set_current_win(parent)
          end
          require("zen-mode").open()
          if cur ~= parent and vim.api.nvim_win_is_valid(cur) then
            vim.api.nvim_set_current_win(cur)
          end
        end
      end)
    end
    vim.schedule(function()
      if vim.fn.mode(1) == "n" then
        try_open_zen()
      else
        local augroup = vim.api.nvim_create_augroup("ZenPickRestore", { clear = true })
        vim.api.nvim_create_autocmd("ModeChanged", {
          group = augroup,
          pattern = "t->*",
          once = true,
          callback = try_open_zen,
        })
      end
    end)
  end
end

function M.schedule_after_pick()
  local attempts = 0
  local function after_picker_returns()
    if vim.fn.mode(1) == "n" or attempts == 50 then
      M.after_pick()
      return
    end
    attempts = attempts + 1
    vim.defer_fn(after_picker_returns, 10)
  end
  vim.defer_fn(after_picker_returns, 10)
end

---Map each harness to its live terminal buffer, for the picker preview.
---@return table<string, number> harness_to_bufnr
function M.collect_terminal_bufs()
  local map = {}
  for _, e in ipairs(park.list()) do
    map[e.harness] = e.buff_nr
  end
  return map
end

---Build a telescope entry for one harness row: an optional work-status dot (for initialized
---harnesses) followed by the harness name in its HarnessTitle<Name> group. The dot and the name are
---highlighted independently so the selected-row dimming (TelescopeSelection links to Visual, no fg)
---leaves both colored. Uninstalled harnesses render dimmed with a "(not installed)" suffix.
---@param name string harness name
---@param bufs table<string, number> map of harness name to live terminal buffer (from collect_terminal_bufs)
---@param installed? boolean whether the harness CLI is on PATH (default true)
---@return table entry { value, ordinal, display }
function M.make_entry(name, bufs, installed)
  if installed == nil then
    installed = true
  end
  -- Never-opened and uninstalled harnesses get no dot.
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
        table.insert(ranges, { { suffix_start, #text }, title.picker_not_installed_group })
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
---~500ms timer while it runs, keyed by harness name via collect_terminal_bufs().
---@param bufs table<string, number> map of harness name to live terminal buffer (from collect_terminal_bufs)
---@param installed_set? table<string, boolean> true for harnesses whose CLI is on PATH
---@return table previewer
local function make_harness_previewer(bufs, installed_set)
  return require("util.live-previewer").new({
    patterns = {
      { "ErrorMsg", [[\c\<\(error\|fatal\|fail\(ed\)\?\|panic\|denied\|refused\|exception\)\>]] },
      { "WarningMsg", [[\c\<warn\(ing\)\?\>]] },
      { "DiagnosticOk", [[\c\<\(ok\|pass\(ed\)\?\|success\(ful\)\?\|done\|complete\(d\)\?\|ready\)\>]] },
      { "Comment", [[\c\<\(debug\|info\|trace\)\>]] },
    },
    lines = function(entry, winid)
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
      elseif name == M.current() then
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
      return lines
    end,
  })
end

---Order picker rows with the active harness first, followed by harnesses idle as of the
---statusline's last poll.
---@param harnesses table[] entries from agent-state.harnesses()
---@return table[] ordered harness entries
function M.order_harnesses(harnesses)
  local ordered = vim.deepcopy(harnesses)
  local ranks = {}
  for _, h in ipairs(ordered) do
    local rank = 2
    if h.name == M.current() then
      rank = 0
    elseif not h.installed then
      rank = 3
    else
      local state = agent_display.status(h.name)
      if state and (state.status == "idle" or state.status == "stale") then
        rank = 1
      end
    end
    ranks[h.name] = rank
  end
  table.sort(ordered, function(a, b)
    if ranks[a.name] ~= ranks[b.name] then
      return ranks[a.name] < ranks[b.name]
    end
    return a.name < b.name
  end)
  return ordered
end

---Telescope picker over available harness dirs; selecting one calls M.switch.
function M.pick()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  if not ok_pickers then
    vim.notify("harness: telescope.nvim not available", vim.log.levels.ERROR)
    return
  end
  -- Remember whether zen mode is open so after_pick can restore it: the
  -- switch and show flow (M.switch, then after_pick) briefly moves focus to a
  -- non-float window, which closes zen-mode via its WinEnter autocmd.
  local zen_ok, zen_open = pcall(function()
    return require("zen-mode.view").is_open() == true
  end)
  zen_was_open = zen_ok and zen_open
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local agent_state = require("harness-decorators.agent-state")
  local harnesses = M.order_harnesses(agent_state.harnesses())
  -- Terminal buffers to preview (the active harness and every other live one). Captured once at
  -- picker-open; the previewer's refresh timer re-reads these buffers live, so a running harness's
  -- output updates in place.
  local bufs = M.collect_terminal_bufs()
  -- Set of installed harness names, used by both the previewer (status line) and the Enter guard.
  local installed_set = {}
  local active_index = 1
  for index, h in ipairs(harnesses) do
    if h.installed then
      installed_set[h.name] = true
    end
    if h.name == M.current() then
      active_index = index
    end
  end

  pickers
    .new({}, {
      prompt_title = "search",
      results_title = "Harnesses",
      preview_title = "Preview",
      default_selection_index = active_index,
      -- Horizontal: prompt and results on the left, preview on the right.
      layout_strategy = "horizontal",
      layout_config = {
        prompt_position = "bottom",
        -- Preview takes most of the width; the harness list is short.
        preview_width = 0.85,
        preview_cutoff = 12,
        width = 0.4,
        height = 0.8,
      },
      finder = finders.new_table({
        results = harnesses,
        entry_maker = function(h)
          return M.make_entry(h.name, bufs, h.installed)
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
          M.schedule_after_pick()
        end)
        return true
      end,
    })
    :find()
end

return M
