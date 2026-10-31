local sidecar = require("harness-decorators.sidecar")
local utils = require("harness-decorators.utils")
local windows = require("harness-decorators.windows")

-- Handles the HarnessEdit autocmd: opens the edited buffer in an
-- adjacent window and jumps to the exact edit line. Harness-agnostic: it only
-- consumes the normalized change events the watcher fires.
local M = {}

---Dedicated window next to the floating terminal for harness edits.
M.jump_win = nil

---Edit sources keyed by session ID. Each value is a list of records.
M.edit_sources = {}

---Find a non-float window with a named normal buffer.
local function find_adjacent_window()
  return windows.find(function(win)
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative ~= "" then
      return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
    if ok and bt ~= "" then
      return false
    end
    return vim.api.nvim_buf_get_name(buf) ~= ""
  end, { reverse = true })
end

---Find an existing normal window displaying file_path.
---@param file_path string
---@return integer?
local function find_file_window(file_path)
  local target = vim.uv.fs_realpath(file_path) or file_path
  return windows.find(function(win)
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative ~= "" then
      return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local actual = name ~= "" and (vim.uv.fs_realpath(name) or name) or nil
    return actual == target
  end)
end

---Get or validate the jump window. Reuses the existing non-float window
---next to the floating terminal - no new splits created.
local function get_jump_win()
  if M.jump_win and not vim.api.nvim_win_is_valid(M.jump_win) then
    M.jump_win = nil
  end

  if not M.jump_win then
    M.jump_win = find_adjacent_window()
  end

  return M.jump_win
end

-- The zen window is a float, so find_adjacent_window and find_file_window never pick it, and a
-- jump there would land behind zen.
local zen_win = require("util.zen").win

---Perform the actual jump logic.
local function jump_to_edit(data, file_path)
  -- No line number means we can't place the cursor meaningfully (early tool_use
  -- events and Create events carry none), so don't swap the window at all.
  -- When present, starting_line already points at the changed line: the parser
  -- walks the hunk past its leading context lines.
  local line = tonumber(data.starting_line)
  if not line then
    return
  end

  -- Reuse the target's existing window when it is already visible. Setting that buffer on
  -- another work window would display the same buffer twice and leave a duplicate view behind.
  local zwin, zparent = zen_win()
  local win = zwin or find_file_window(file_path) or get_jump_win()
  if not win then
    return
  end

  local bufnr = vim.fn.bufadd(file_path)

  -- Answer SwapExists with 'edit' so the jump never prompts.
  local swap_grp = vim.api.nvim_create_augroup("HarnessJumpSwap", { clear = true })
  vim.api.nvim_create_autocmd("SwapExists", {
    group = swap_grp,
    callback = function()
      vim.v.swapchoice = "e"
    end,
  })

  if vim.uv.fs_stat(file_path) then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd.checktime()
    end)
    -- Load the buffer so BufRead/BufReadPost fire and filetype/syntax get set.
    -- For already-loaded buffers this re-reads from disk (the agent's version wins);
    -- checktime alone only marks externally-changed without actually re-reading.
    -- For new buffers this is what triggers the initial read + FileType chain.
    pcall(vim.fn.bufload, bufnr)
  end

  -- Switch the target window to show this buffer. Suppress autocmds during the switch:
  -- BufLeave/BufWinEnter from plugins have been observed to exit terminal insert
  -- mode as a side effect, creating a gap where keystrokes trigger normal-mode keybinds.
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = "BufLeave,BufEnter,WinEnter,WinLeave"
  local ok_switch, switch_err = pcall(vim.api.nvim_win_set_buf, win, bufnr)
  -- Keep zen's parent on the same buffer so closing zen lands on the edited file.
  if ok_switch and zparent and vim.api.nvim_win_is_valid(zparent) then
    pcall(vim.api.nvim_win_set_buf, zparent, bufnr)
  end
  vim.o.eventignore = saved_ei

  pcall(vim.api.nvim_del_augroup_by_id, swap_grp)

  -- If the switch failed (e.g. despite the guard), skip the deferred cursor set below.
  if not ok_switch then
    utils.log("jump window switch failed: " .. tostring(switch_err), vim.log.levels.WARN)
    return
  end

  -- Defer cursor set so we run after any plugin BufWinEnter callbacks that restore
  -- the last-known cursor position and would otherwise override us.
  vim.defer_fn(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    -- Re-read the line count at set-time (not cached): the buffer may have been
    -- reloaded since jump_to_edit started. clamp_line keeps the target in
    -- [1, max] so a race between reload and cursor-set can never throw into
    -- the timer.
    local target = utils.clamp_line(line, vim.api.nvim_buf_line_count(bufnr))
    local ok, err = pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    if not ok then
      utils.log("cursor set failed: " .. tostring(err), vim.log.levels.WARN)
    end
    -- Switching a non-current window's buffer under eventignore
    -- (BufLeave,BufEnter,WinEnter,WinLeave) can leave the grid out of sync: the jump
    -- window paints its cursor while the terminal (the actual current window) doesn't
    -- reclaim it. Force a redraw to resync the display.
    if ok then
      vim.cmd.redraw()
      -- Refresh an open neo-tree in place so it shows new files.
      vim.defer_fn(function()
        local ok_mgr, manager = pcall(require, "neo-tree.sources.manager")
        if not ok_mgr then
          return
        end
        -- get_state auto-creates a state on demand, so a non-nil result is NOT proof
        -- the tree is open. Scan for a live neo-tree window and refresh its state.
        for _, tree_win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(tree_win)
          if vim.bo[buf].filetype == "neo-tree" then
            local state = manager.get_state("filesystem", nil, tree_win)
            pcall(require("neo-tree.sources.filesystem.commands").refresh, state)
            return
          end
        end
      end, 100)
    end
    require("harness-decorators.term").ensure_terminal_mode()
  end, 100)
end

---Store an edit source record. Skips incomplete events, deduplicates in-place.
---Records are grouped by session ID, so switching sessions doesn't pollute
---the history of the previous one. Sidecar path is derived from the session
---ID at storage time and cached on the record for later Telescope lookup.
---@param data table from autocmd args.data
local function store_edit_source(data)
  local file_path = data.file_path
  local jsonl_path = data.jsonl_path
  local source_line = data.source_line
  local starting_line = data.starting_line
  local operation = data.operation or "Edit"
  local event_uuid = data.event_uuid
  local event_timestamp = data.event_timestamp
  local event_id = data.event_id

  -- Skip incomplete events: file_path is required.
  if not file_path then
    return
  end

  -- Generate timestamp on arrival (epoch-ms, at os.time's one-second resolution).
  local timestamp = os.time() * 1000

  local session_id = utils.extract_session_id(jsonl_path)
  if not session_id then
    return
  end

  local sidecar_path = sidecar.path(session_id)

  local new_record = {
    timestamp = timestamp,
    time_str = utils.format_time(timestamp),
    file_path = file_path,
    source_line = source_line,
    starting_line = starting_line,
    operation = operation,
    event_uuid = event_uuid,
    event_timestamp = event_timestamp,
    event_id = event_id,
    sidecar_path = sidecar_path,
  }

  local list = M.edit_sources[session_id]
  if not list then
    list = {}
    M.edit_sources[session_id] = list
  end

  -- Dedup for same-file events within 5s:
  --   1. Last has starting_line, new doesn't: drop new.
  --   2. New has starting_line: replace last in place.
  --   3. Neither has starting_line nor source_line: replace last in place.
  local last = list[#list]
  if last and last.file_path == file_path then
    local time_diff = math.abs(last.timestamp - timestamp)
    if time_diff < 5000 then -- within 5 seconds counts as the same edit
      if last.starting_line and not starting_line then
        return -- prefer the record that already has a line number
      end
      if starting_line or (not last.source_line and not source_line) then
        list[#list] = new_record -- upgrade or dedup
        return
      end
    end
  end

  table.insert(list, new_record)
end

---Trailing-edge debounce to the latest edit: per-event deferred jumps can overlap event
---suppression and starve terminal re-entry, leaving terminal-normal mode.
local _pending_jump = nil
local _pending_args = nil

local function schedule_jump(args)
  _pending_args = args
  if _pending_jump then
    -- A jump is already queued: reset it so the burst collapses into the
    -- latest event. The queued callback re-reads _pending_args at fire time.
    _pending_jump:stop()
  end
  _pending_jump = vim.defer_fn(function()
    _pending_jump = nil
    local data = _pending_args
    _pending_args = nil
    if not data then
      return
    end
    -- The edit jump lands focus in the terminal; first point the work window at
    -- the last normal-mode buffer so it stays visible underneath.
    local focus = require("harness-decorators.focus")
    focus.suppress_next_leave()
    focus.restore()
    jump_to_edit(data.data, data.data.file_path)
  end, 250)
end

---Jump to the edited file without stealing focus from the terminal.
function M.on_edit(args)
  if not args.data then
    return
  end
  local file_path = args.data.file_path
  if type(file_path) ~= "string" or #file_path == 0 then
    return
  end

  store_edit_source(args.data)

  schedule_jump(args)
end

---Create the autocmds that trigger jump behavior. Call from init setup.
function M.create_jump_autocmds(group)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HarnessEdit",
    callback = M.on_edit,
  })
end

return M
