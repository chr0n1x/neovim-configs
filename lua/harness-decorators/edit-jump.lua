local sidecar = require("harness-decorators.sidecar")
local utils = require("harness-decorators.utils")

-- Handles the HarnessEdit autocmd: opens the edited buffer in an
-- adjacent window and jumps to the exact edit line. Harness-agnostic: it only
-- consumes the normalized change events the watcher fires.
local M = {}

---Set true while a jump is in flight so the TermLeave guard knows to restore insert mode.
local _jump_active = false

---Dedicated window next to the floating terminal for Claude Code edits.
M.jump_win = nil

---Edit sources keyed by session ID. Each value is a list of records.
M.edit_sources = {}

---Find a non-float window with a real file buffer.
local function find_adjacent_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for ix = #wins, 1, -1 do
    local win_id = wins[ix]
    local cfg = vim.api.nvim_win_get_config(win_id)
    -- config.relative is "" for normal windows, non-empty for floats.
    if cfg.relative ~= "" then
      goto continue
    end
    local buf = vim.api.nvim_win_get_buf(win_id)
    local ok, bt = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
    -- Skip terminal, nofile, help, etc. — only normal file buffers.
    if ok and bt ~= "" then
      goto continue
    end
    if vim.api.nvim_buf_get_name(buf) ~= "" then
      return win_id
    end
    ::continue::
  end
  return nil
end

---Find an existing normal window displaying file_path.
---@param file_path string
---@return integer?
local function find_file_window(file_path)
  local target = vim.uv.fs_realpath(file_path) or file_path
  for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win_id)
    if cfg.relative == "" then
      local buf = vim.api.nvim_win_get_buf(win_id)
      local name = vim.api.nvim_buf_get_name(buf)
      local actual = name ~= "" and (vim.uv.fs_realpath(name) or name) or nil
      if actual == target then
        return win_id
      end
    end
  end
  return nil
end

---Get or validate the jump window. Reuses the existing non-float window
---next to the floating terminal — no new splits created.
local function get_jump_win()
  if M.jump_win and not vim.api.nvim_win_is_valid(M.jump_win) then
    M.jump_win = nil
  end

  if not M.jump_win then
    M.jump_win = find_adjacent_window()
  end

  return M.jump_win
end

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
  local win = find_file_window(file_path) or get_jump_win()
  if not win then
    return
  end

  -- Load the buffer without switching the active window or touching terminal mode.
  -- The harness just wrote the file on disk, so re-read it even if the buffer is
  -- already loaded. bufadd creates the entry; checktime detects the external change;
  -- bufload re-reads from disk (the agent's version wins). Neither changes the window.
  local bufnr = vim.fn.bufadd(file_path)

  -- The agent may have written a file the user also has open with unsaved
  -- changes, or a stale <file>.swp may linger. Loading such a file (checktime/
  -- bufload/win_set_buf) raises E325 ATTENTION and pops an interactive swap
  -- prompt mid-jump — which, uncaught, escaped this scheduled callback and left
  -- eventignore pinned to "all" (every autocmd globally suppressed) with
  -- _jump_active stuck true. Auto-answer SwapExists with "edit anyway" so the
  -- jump stays silent and non-blocking; the on-disk (agent) version is exactly
  -- what we want to display.
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
  _jump_active = true

  local saved_ei = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok_switch, switch_err = pcall(vim.api.nvim_win_set_buf, win, bufnr)
  vim.o.eventignore = saved_ei

  pcall(vim.api.nvim_del_augroup_by_id, swap_grp)

  -- If the switch failed (e.g. despite the guard), unwind cleanly: never leave
  -- _jump_active latched, and skip the deferred cursor set below.
  if not ok_switch then
    _jump_active = false
    utils.log("jump window switch failed: " .. tostring(switch_err), vim.log.levels.WARN)
    return
  end

  -- Defer cursor set so we run after any plugin BufWinEnter callbacks that restore
  -- the last-known cursor position and would otherwise override us.
  vim.defer_fn(function()
    _jump_active = false
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
    -- Switching a non-current window's buffer under eventignore=all can leave the
    -- grid out of sync: the jump window paints its cursor while the terminal (the
    -- actual current window) doesn't reclaim it, so the visible cursor appears to
    -- sit in the jumped-to file. Force a redraw to resync the display.
    if ok then
      vim.cmd.redraw()
      -- Refresh neo-tree's filesystem listing after the jump so it reflects files
      -- the agent just wrote. Uses the source refresh command (not `NeoTree reveal`)
      -- so it updates in place without stealing focus, re-centering, or opening a
      -- closed tree. Guarded: only fires when a neo-tree window is actually open.
      -- Deferred past the cursor set so its redraw doesn't fight ours.
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
    local ok_term, term = pcall(require, "harness-decorators.term")
    if ok_term and type(term.ensure_terminal_mode) == "function" then
      term.ensure_terminal_mode()
    end
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

  -- Generate timestamp on arrival (epoch-ms via os.time).
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

  -- Dedup / skip logic for same-file events arriving close together:
  --   1. Last has starting_line, new doesn't → drop new (incomplete).
  --   2. Last missing starting_line, new has one → replace last in-place
  --      with the better record.
  --   3. Both missing starting_line → replace last in-place (duplicate).
  local last = list[#list]
  if last and last.file_path == file_path then
    local time_diff = math.abs(last.timestamp - timestamp)
    if time_diff < 5000 then -- within 5 seconds = same edit
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

  vim.defer_fn(function()
    -- The edit jump lands focus in the terminal; first point the work window at
    -- the last normal-mode buffer so it stays visible underneath.
    local fok, focus = pcall(require, "harness-decorators.focus")
    if fok then
      focus.suppress_next_leave()
      focus.restore()
    end
    jump_to_edit(args.data, file_path)
  end, 500)
end

---Create the autocmds that trigger jump behavior. Call from init setup.
function M.create_jump_autocmds(group)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HarnessEdit",
    callback = M.on_edit,
  })

  -- If something knocks the terminal out of insert mode while a jump is in flight,
  -- restore it immediately. TermLeave fires the instant insert mode is exited,
  -- so the gap between the exit and our startinsert() is one vim.schedule tick.
  vim.api.nvim_create_autocmd("TermLeave", {
    group = group,
    callback = function()
      if _jump_active then
        local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
          vim.schedule(function()
            if _jump_active then
              vim.cmd.startinsert()
            end
          end)
        end
      end
    end,
  })
end

return M
