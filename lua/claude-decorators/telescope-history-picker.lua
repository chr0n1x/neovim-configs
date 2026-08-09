local sidecar = require("claude-decorators.sidecar")

local M = {}

---Highlight group names for preview regions.
local SIDECAR_DATE_HL = "ClaudeSidecarDate"
local SIDECAR_PATH_HL = "ClaudeSidecarPath"
local SIDECAR_DIFF_NUM = "ClaudeSidecarDiffNum"
local SIDECAR_DIFF_ADD = "ClaudeSidecarDiffAdd"
local SIDECAR_DIFF_DEL = "ClaudeSidecarDiffDel"

---Register all highlight groups if they don't exist yet.
local function ensure_hl()
  local groups = {
    [SIDECAR_DATE_HL] = { fg = "#888888", bold = true, default = true },
    [SIDECAR_PATH_HL] = { fg = "#ffffff", bold = true, default = true },
    [SIDECAR_DIFF_NUM] = { fg = "#555555", default = true },
    [SIDECAR_DIFF_ADD] = { fg = "#98C379", bg = "#1e3a1f", default = true },
    [SIDECAR_DIFF_DEL] = { fg = "#E06C75", bg = "#3a1e1f", default = true },
  }
  for name, hl in pairs(groups) do
    local has, existing = pcall(vim.api.nvim_get_hl, 0, { name = name })
    if not has or not existing.foreground then
      vim.api.nvim_set_hl(0, name, hl)
    end
  end
end

---Strip the CWD prefix from a path if it's under CWD.
local function shorten_path(fp)
  local cwd = vim.fn.getcwd()
  if fp:sub(1, #cwd + 1) == cwd .. "/" then
    return "./" .. fp:sub(#cwd + 2)
  end
  return fp
end

---Build a Telescope previewer that renders diffs from the sidecar file.
local function make_previewer()
  local previewers = require("telescope.previewers")

  return previewers.new_buffer_previewer({
    title_fn = function(entry)
      local e = entry.value
      local line_part = e.starting_line and ":" .. e.starting_line or ""
      return e.file_path .. line_part
    end,
    define_preview = function(self, entry)
      local bufnr = self.state.bufnr
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
      vim.api.nvim_buf_set_option(bufnr, "filetype", "diff")

      ensure_hl()

      local e = entry.value
      if not e.sidecar_path or not e.event_uuid then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          "(no sidecar data available for this entry)",
        })
        vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
        return
      end

      local event = sidecar.lookup(e.sidecar_path, e.event_uuid, e.event_timestamp, e.event_id)
      local diff_text = sidecar.extract_diff(event)

      -- Build header: date (dim) + path (bright), shortened if under CWD.
      local short_path = shorten_path(e.file_path)
      local header_line = string.format("%s %s", e.time_str, short_path)

      -- Strip the delta line from diff_text if extract_diff already added it.
      local lines = vim.split(diff_text, "\n")
      if #lines > 0 and lines[1]:find("%d+ -> %d+ lines") then
        table.remove(lines, 1) -- remove old delta header
      end
      -- Strip leading blank line from diff_text if present.
      if #lines > 0 and #lines[1] == 0 then
        table.remove(lines, 1)
      end

      table.insert(lines, 1, "") -- blank after header
      table.insert(lines, 1, header_line)

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      -- Line 0: header. Date part gets dim highlight, path part gets bright.
      -- Split at " - " for selective highlighting.
      local sep = e.time_str
      local date_len = #sep
      vim.api.nvim_buf_add_highlight(bufnr, 0, SIDECAR_DATE_HL, 0, 0, date_len)
      vim.api.nvim_buf_add_highlight(bufnr, 0, SIDECAR_PATH_HL, 0, date_len, -1)

      -- Line 1: blank separator — skip.
      -- Lines 2+: diff content from extract_diff.
      -- Format is "%5d  <prefix><content>" where <prefix> is +|-|space.
      -- The prefix char is always at string position 8 (1-indexed).
      for tbl_idx = 3, #lines do
        local line = lines[tbl_idx]
        local buf_line = tbl_idx - 1
        if line ~= nil and line ~= "" then
          local prefix = line:sub(8, 8)
          if prefix == "+" then
            vim.api.nvim_buf_add_highlight(bufnr, 0, SIDECAR_DIFF_ADD, buf_line, 0, -1)
          elseif prefix == "-" then
            vim.api.nvim_buf_add_highlight(bufnr, 0, SIDECAR_DIFF_DEL, buf_line, 0, -1)
          else
            -- Context or no number: dim the leading number.
            local _, ne = line:find("^%s*[0-9]+")
            if ne then
              vim.api.nvim_buf_add_highlight(bufnr, 0, SIDECAR_DIFF_NUM, buf_line, 0, ne + 1)
            end
          end
        end
      end

      vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
    end,
  })
end

---Open a Telescope picker showing all recorded edit sources.
function M.pick()
  local edit_jump = require("claude-decorators.edit-jump")
  local inotify = require("claude-decorators.inotify-watcher")
  local utils = require("claude-decorators.utils")

  -- Determine current session from the pinned JSONL path (source of truth).
  local pinned_path = inotify.pinned_jsonl_path
  local current_session = utils.extract_session_id(pinned_path) or nil

  -- If we can't determine the current session, fall back to the most recent
  -- session that has records, for backwards compatibility.
  if not current_session then
    for sid, records in pairs(edit_jump.edit_sources) do
      if #records > 0 then
        current_session = sid
        break
      end
    end
  end

  -- Only show records for the current session.
  local records = edit_jump.edit_sources[current_session] or {}

  local entries = {}
  for _, r in ipairs(records) do
    table.insert(entries, {
      session_id = current_session,
      timestamp = r.timestamp,
      time_str = r.time_str,
      file_path = r.file_path,
      source_line = r.source_line,
      starting_line = r.starting_line,
      operation = r.operation or "Edit",
      event_uuid = r.event_uuid,
      event_timestamp = r.event_timestamp,
      event_id = r.event_id,
      sidecar_path = r.sidecar_path,
    })
  end

  -- Sort by timestamp so most recent is at the top.
  table.sort(entries, function(a, b)
    return a.timestamp > b.timestamp
  end)

  local session_display = current_session or "(??)"
  -- Truncate long session IDs for display.
  local short_id = session_display:sub(1, 8) .. ".."

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local display_entries = #entries > 0 and entries or {}

  local picker_opts = {
    prompt_title = "🦀 " .. short_id .. " - Change History",
    results_title = "🦀 " .. short_id .. " - Change History",
    finder = finders.new_table({
      results = display_entries,
      entry_maker = function(entry)
        local line_part = entry.starting_line and ":" .. entry.starting_line or ""
        local short_path = shorten_path(entry.file_path)
        local display = string.format("%-8s  %-19s  %s%s", entry.operation, entry.time_str, short_path, line_part)
        return {
          value = entry,
          display = display,
          ordinal = string.format(
            "%s %s %s %s",
            entry.operation,
            entry.time_str,
            entry.file_path,
            tostring(entry.starting_line or "")
          ),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = make_previewer(),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.value then
          return
        end

        actions.close(prompt_bufnr)

        local entry = selection.value
        local file_path = entry.file_path
        local line = entry.starting_line

        -- Use edit-jump's jump window if available, otherwise just :edit.
        local win = edit_jump.jump_win
        if win and vim.api.nvim_win_is_valid(win) then
          if line then
            vim.cmd(string.format("edit +%d %s", line, vim.fn.fnameescape(file_path)))
          else
            vim.cmd("edit " .. vim.fn.fnameescape(file_path))
          end
          -- Set cursor in the jump window after edit.
          if vim.api.nvim_win_is_valid(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            if line then
              local max_line = vim.api.nvim_buf_line_count(buf)
              vim.api.nvim_win_set_cursor(win, { math.min(line, math.max(1, max_line)), 0 })
            end
          end
        else
          if line then
            vim.cmd(string.format("edit +%d %s", line, vim.fn.fnameescape(file_path)))
          else
            vim.cmd("edit " .. vim.fn.fnameescape(file_path))
          end
        end
      end)
      return true
    end,
  }

  pickers.new(picker_opts):find()
end

return M
