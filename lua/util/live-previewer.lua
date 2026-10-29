local M = {}

---Telescope buffer previewer that re-renders every 500ms so a running terminal's output updates
---in place. Matches from `patterns` are highlighted in the preview window.
---@param opts { lines: fun(entry: table, winid: integer): string[], patterns: string[][]? }
---  patterns is a list of { highlight_group, vim_regex } pairs.
function M.new(opts)
  local previewers = require("telescope.previewers")
  local patterns = opts.patterns or {}
  local active_timer = nil

  local function stop_timer()
    active_timer = require("harness-decorators.utils").close_timer(active_timer)
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
    local lines = opts.lines(entry, winid)
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

return M
