-- Remembers the last non-terminal window so focus-gaining actions (<leader>c, the
-- float's <Esc>/<C-h>, edit-jump) can restore it. Captured on WinLeave.
--
-- AGENTS: the guards below (_restoring/_suppress/_skip_buf/_skip_restore_buf and the
-- "already shown elsewhere" bail in restore()) each prevent a specific buffer-
-- duplication regression. Do not remove or simplify them without re-running the
-- neo-tree <leader>c repro (see docs/focus-duplication-debug.md).
local M = {}

M.last_win = nil -- last non-terminal window we left

local _restoring = false -- true while restore() is re-pointing a window
local _suppress = false -- true across a transition through the float; capture() skips it
local _skip_buf = nil -- buffer last captured; capture() won't re-record a window showing it
local _skip_restore_buf = nil -- buffer last left; restore() bails if we're still in it

---Capture the current window as the restore target. Called from WinLeave; skips
-- terminal windows and any transition the guards mark as ours to ignore.
--
-- _suppress is a one-shot "skip the NEXT leave" flag (see suppress_next_leave). It is set by
-- jump_to_saved / go_back / <leader>c to ignore the WinLeave their own window move triggers,
-- but nothing else clears it - so capture() must consume it here. Without that, a <C-h>
-- (jump_to_saved) latches _suppress true and every later capture bails, leaving last_win
-- stale: <leader>ca from a file buffer then <C-h> would return to the old window instead of
-- the file buffer we just left.
function M.capture()
  if _restoring or _suppress then
    _suppress = false -- consume the one-shot suppress so it doesn't poison later captures
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
    return
  end
  if _skip_buf and buf == _skip_buf then
    return
  end
  M.last_win = win
  _skip_buf = buf
  _skip_restore_buf = buf
end

---Mark the next WinLeave as part of a terminal-focus transition so capture() skips it.
function M.suppress_next_leave()
  _suppress = true
end

---Move focus to the last captured window (the one we came from). Returns true if it
-- moved, false if there is no saved window or it has been closed (caller falls back).
function M.jump_to_saved()
  local win = M.last_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  _suppress = true
  pcall(vim.api.nvim_set_current_win, win)
  return true
end

---Re-point the current window at the last captured buffer. No-op if there is no saved
-- window, we're still standing in it, or that buffer is already shown in another live
-- window (stealing it would orphan a duplicate - the neo-tree <leader>c regression).
function M.restore()
  _suppress = false
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  if _skip_restore_buf and cur_buf == _skip_restore_buf then
    return false
  end
  _skip_buf = nil
  _skip_restore_buf = nil
  local win = M.last_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  -- Bail if the saved buffer is already on screen in a different window.
  if buf ~= cur_buf then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= cur_win and vim.api.nvim_win_get_buf(w) == buf then
        return false
      end
    end
  end
  _restoring = true
  pcall(vim.fn.bufload, buf)
  pcall(vim.api.nvim_win_set_buf, cur_win, buf)
  _restoring = false
  return true
end

---Clear all internal state (saved window and every guard). Used to start from a clean
-- slate - e.g. by tests, or if a transition left a guard stuck. After this, the next
-- capture() records fresh.
function M.reset()
  M.last_win = nil
  _restoring = false
  _suppress = false
  _skip_buf = nil
  _skip_restore_buf = nil
end

return M
