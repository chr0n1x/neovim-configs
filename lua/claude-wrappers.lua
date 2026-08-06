-- Custom wrappers and hooks for claudecode.nvim
-- Extends the plugin with auto-follow behavior for automode edits

local M = {}

local function log_message(msg, level)
  vim.notify("[claude.nvim auto-follow] " .. msg, level or vim.log.levels.INFO)
end

-- check if the Claude Code terminal is currently visible.
local function claude_terminal_visible()
  local ok, terminal = pcall(require, "claudecode.terminal")
  if not ok then return false end
  local bufnr = terminal.get_active_terminal_bufnr and terminal.get_active_terminal_bufnr()
  if not bufnr then return false end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

-- check if a file path is noise (temp/swap files).
local function is_noise(file_path)
  if type(file_path) ~= "string" or #file_path == 0 then return true end
  return file_path:match("%.tmp%d*$")
    or file_path:match("%.sw[npx]$")
    or file_path:match("~$")
    or file_path:match("^/proc/")
    -- not sure about these
    -- or file_path:match("%.%d+%.$")
    -- or file_path:match("^/tmp/")
end

-- ==========================================================================
-- LOG FILE EDIT DETECTOR
--
-- On each poll: dump terminal buffer to log file, read it back,
-- diff line count against previous read, parse new lines for tool calls.
-- All parsing is done on the log file content (not the terminal buffer)
-- since terminal buffers return empty lines from nvim_buf_get_lines.
-- ==========================================================================

---Config: max lines to keep in the log file (-1 = unlimited).
local MAX_LOG_LINES = -1
local poll_timer = nil
local log_path = nil            -- computed in setup()
local ESC = "\27"

---Strip all ANSI escape sequences from a terminal line.
local function strip_ansi(line)
  line = line:gsub(ESC .. "%[[0-9;?]*[a-zA-Z]", "")
  line = line:gsub(ESC .. "%].*?(\x07|" .. ESC .. "%\\)", "")
  line = line:gsub(ESC .. ".", "")
  return line
end

local FILE_TOOLS = {
  Write = true,
  Edit = true,
  Update = true,
  NotebookEdit = true,
}

-- parse a single stripped line for a tool call like "● Write(path)".
local function parse_tool_call(line)
  local _bullet, tool_name, fp = line:match("^%s*([^%s]+) (%a+)%(([^)]+)%)")
  if not _bullet or not tool_name then return end
  if _bullet:match("^%a") then return end       -- reject alphanumeric bullets
  if not FILE_TOOLS[tool_name] then return end
  if is_noise(fp) then return end

  -- make sure this is a real path before we pass it downstream
  local f = io.open(fp, "r")
  if f then f:close() end
  if not f then return end

  return { path = fp, tool_name = tool_name }
end

---Get the terminal buffer lines (best effort — may be empty for terminal bufs).
local function get_term_lines()
  local ok, terminal = pcall(require, "claudecode.terminal")
  if not ok then return nil end
  local bufnr = terminal.get_active_terminal_bufnr and terminal.get_active_terminal_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  return vim.fn.getbufline(bufnr, 0, vim.api.nvim_buf_line_count(bufnr) - 1)
end

---Write lines to the log file, respecting MAX_LOG_LINES.
local function write_log(lines)
  if not log_path then return end
  local content = table.concat(lines, "\n") .. "\n"

  if MAX_LOG_LINES > 0 and #lines > MAX_LOG_LINES then
    content = table.concat({ unpack(lines, #lines - MAX_LOG_LINES + 1) }, "\n") .. "\n"
  end

  local f = io.open(log_path, "w")
  if f then
    f:write(content)
    f:close()
  end
end

---Read lines from the log file. Returns nil if file doesn't exist.
local function read_log()
  if not log_path then
    log_message("invalid log_path", vim.log.levels.WARN)
    return nil
  end
  local f = io.open(log_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local result = {}
  for line in content:gmatch("([^\n]*)\n?") do
    result[#result + 1] = line
  end
  if #result > 0 and result[#result] == "" then table.remove(result) end
  return result
end

local function filter_empty(lines)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%s*$") then
      table.remove(lines, i)
    end
  end
  return lines
end

---Poll: diff old vs new log, parse new lines for tool calls. Debug mode.
local function poll_terminal()
  if not claude_terminal_visible() then
    return
  end

  -- Read existing log before writing.
  local old_lines = read_log()
  local old_count = old_lines and #old_lines or 0

  -- Try to get terminal content and write it as the full snapshot.
  local term_lines = get_term_lines()
  if term_lines then
    local has_content = false
    for _, l in ipairs(term_lines) do
      if #l > 0 then
        has_content = true
        break
      end
    end
    if has_content then
      write_log(term_lines)
    end
  end

  -- we JUST started with a FRESH log here, so something resumed or the
  -- terminal was initialized so seed (in the if clause above) & exit
  if old_count == 0 then
    return
  end

  -- not initialization step so continue to eval
  local new_lines = read_log()
  if not new_lines or #new_lines == 0 then
    return
  end
  local new_count = #new_lines

  if new_count == old_count or new_count < old_count then
    return
  end

  local old_lines_filtered = filter_empty(old_lines)
  local new_start = #old_lines_filtered + 1
  local new_filtered_lines = filter_empty(new_lines)
  local new_filtered_count = #new_filtered_lines
  local added = new_filtered_count - #old_lines_filtered
  -- local function slice(tbl, start_from_last)
  --   local sliced = {}
  --   local start_index = #tbl - start_from_last + 1
  --
  --   for i = start_index, #tbl do
  --     table.insert(sliced, tbl[i])
  --   end
  --   return sliced
  -- end
  -- local sliced = slice(new_lines, 50)
  log_message(
    "EVALUATING; diff: old=" .. #old_lines_filtered .. " new=" .. new_filtered_count .. " added=" .. added,
    --.. " contents=".. vim.inspect(sliced),
    vim.log.levels.DEBUG
  )

  if added <= 0 then
    return
  end
  if added < 30 then
    new_start = #new_filtered_lines - 50
    if new_start <= 0 then
      new_start = 0
    end
  end

  -- filter out empty lines so that metadata gathering data below works
  -- for i = #new_lines, 1, -1 do
  --   if new_lines[i]:match("^%s*$") then
  --     table.remove(new_lines, i)
  --   end
  -- end

  -- Parse only the new lines.
  for i = new_start, new_filtered_count do
    local stripped = strip_ansi(new_filtered_lines[i])
    log_message("eval line: " .. stripped, vim.log.levels.DEBUG)
    local info = parse_tool_call(stripped)
    if info then
      log_message("--> info: " .. vim.inspect(info), vim.log.levels.DEBUG)
      local delta_info = new_filtered_lines[i+1]
      log_message("--> delta info: " .. vim.inspect(delta_info), vim.log.levels.DEBUG)
      local change_first_line = new_filtered_lines[i+2]
      log_message("--> line start: " .. vim.inspect(change_first_line), vim.log.levels.DEBUG)
      -- found a valid tool invocation, look ahead
      -- if we cannot look ahead maybe the log has not fully updated yet
      if delta_info ~= nil and change_first_line ~= nil then
        log_message("--> constructing diff data", vim.log.levels.DEBUG)

        local change_info = {
          file_path = info.path,
          operation = info.tool_name,
          delta = delta_info:gsub("^[^%w]+", ""):gsub("[^%w]+$", ""),
          starting_line = tonumber(string.match(strip_ansi(change_first_line), "%d+")),
        }
        log_message("--> " .. vim.inspect(change_info), vim.log.levels.DEBUG)

        local seen = M.tool_at_path_pos_seen(
          change_info.file_path,
          change_info.operation,
          i
        )
        log_message("--> " .. i, vim.log.levels.DEBUG)
        if seen then
          log_message(
            "NOT firing autocmd ClaudeAutoFollowEdit; SEEN @ " .. change_info.file_path .. ":" .. change_info.starting_line,
            vim.log.levels.DEBUG
          )
          break
        end

        log_message(
          "detected edit @ " .. change_info.file_path .. ":" .. change_info.starting_line ..
          " (" .. change_info.operation .. " - " .. change_info.delta .. ")"
        )

        log_message(
          "firing autocmd ClaudeAutoFollowEdit @ " .. change_info.file_path .. ":" .. change_info.starting_line,
          vim.log.levels.DEBUG
        )

        vim.api.nvim_exec_autocmds("User", {
          pattern = "ClaudeAutoFollowEdit",
          data = change_info,
        })

        -- the check above should have seeded this
        M.tool_uses[change_info.file_path][change_info.tool_name][i] = true
      end
    end
  end
end

---Start the poll timer.
local function start_watch()
  if poll_timer then return end
  poll_timer = vim.uv.new_timer()
  poll_timer:start(0, 1000, vim.schedule_wrap(function()
    pcall(poll_terminal)
  end))
end

---Stop the poll timer and reset state.
local function stop_watch()
  if poll_timer then
    pcall(function() poll_timer:stop() end)
    pcall(function() poll_timer:close() end)
    poll_timer = nil
  end
end

-- ==========================================================================
-- EDIT JUMP HANDLER
-- ==========================================================================

---Jump to the edited file without stealing focus from the terminal.
local function on_edit(args)
  if not args.data then return end
  local file_path = args.data.file_path
  if type(file_path) ~= "string" or #file_path == 0 then return end

  vim.defer_fn(function()
    vim.cmd("checktime")

    -- Don't steal focus if the user is in the terminal.
    local cur_buf = vim.api.nvim_win_get_buf(0)
    if vim.bo[cur_buf].buftype == "terminal" then return end

    local bufnr = vim.fn.bufnr(file_path)

    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      -- Already loaded — jump to the window showing it.
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
          vim.api.nvim_set_current_win(w)
          return
        end
      end
    end

    -- Not loaded or not visible — open it in the first non-terminal window.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= "terminal" then
        vim.api.nvim_set_current_win(w)
        vim.cmd("edit " .. vim.fn.fnameescape(file_path))
        return
      end
    end
  end, 500)
end

-- ==========================================================================
-- SETUP
-- ==========================================================================

M.setup_auto_follow = function(pid)
  if not pid then
    log_message("No PID passed in from init", vim.log.levels.ERROR)
    return
  end
  local group = vim.api.nvim_create_augroup("ClaudeAutoFollow", { clear = true })
  local user = os.getenv("USER") or "unknown"
  local dir = "/tmp/nvim." .. user
  log_path = dir .. "/pid-" .. pid .. "-claude.nvim.log"

  -- Remove any leftover log from a previous session to start fresh.
  pcall(vim.fn.delete, log_path)

  -- Ensure the directory exists.
  local ok, _ = pcall(vim.fn.mkdir, dir, "p")
  if not ok then
    log_message("failed to create log dir: " .. dir, vim.log.levels.WARN)
    return
  end

  log_message("logging terminal to: " .. log_path, vim.log.levels.INFO)

  -- Path 1: diff accepted (review mode).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeCodeDiffClosed",
    callback = function(args)
      if not args.data or not args.data.reason then return end
      if not args.data.reason:find("save") then return end
      on_edit(args)
    end,
  })

  -- Path 2: automode direct edits detected via terminal watcher.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeAutoFollowEdit",
    callback = on_edit,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      stop_watch()
      if log_path then
        pcall(vim.fn.delete, log_path)
      end
    end,
  })

  M.tool_uses = {}
  start_watch()
end

M.tool_at_path_pos_seen = function(path, tool, pos)
  if not (path and tool and pos) then
    return false
  end

  M.tool_uses[path] = M.tool_uses[path] or {}
  M.tool_uses[path][tool] = M.tool_uses[path][tool] or {}

  return M.tool_uses[path][tool][pos] ~= nil
end

M.setup = function()
  local ok, err = pcall(M.setup_auto_follow, vim.loop.os_getppid())
  if not ok then
    log_message("setup failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

return M
