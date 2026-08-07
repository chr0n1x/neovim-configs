local M = {}

---Open a Telescope picker showing all recorded edit sources.
function M.pick()
  local edit_jump = require("claude-decorators.edit-jump")
  local edit_sources = edit_jump.edit_sources

  -- Flatten sessions into a single list of entries.
  local entries = {}
  for session_id, records in pairs(edit_sources) do
    for _, r in ipairs(records) do
      table.insert(entries, {
        session_id = session_id,
        timestamp = r.timestamp,
        time_str = r.time_str,
        file_path = r.file_path,
        source_line = r.source_line,
        starting_line = r.starting_line,
        operation = r.operation or "Edit",
      })
    end
  end

  -- Sort by timestamp so most recent is at the top.
  table.sort(entries, function(a, b) return a.timestamp > b.timestamp end)

  -- Use the most recent session ID in the title.
  local current_session = #entries > 0 and entries[1].session_id or "none"
  -- Truncate long session IDs for display.
  local short_id = current_session:sub(1, 8) .. "..."

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local display_entries = #entries > 0 and entries or {}

  local picker_opts = {
    prompt_title = "🦀 " .. short_id .. " — Change History",
    results_title = false,
    finder = finders.new_table({
      results = display_entries,
      entry_maker = function(entry)
        local line_part = entry.starting_line
            and ":" .. entry.starting_line
            or ""
        local display = string.format(
          "%-8s  %-19s  %s%s",
          entry.operation,
          entry.time_str,
          entry.file_path,
          line_part
        )
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
    sorter = conf.generic_sorter{},
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.value then return end

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
