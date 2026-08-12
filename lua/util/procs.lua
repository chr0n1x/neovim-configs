local M = {}

local registry = {}
local buf_to_name = {}
local attached_bufs = {}
-- Set while toggle() is running so on_win can record which name owns a new buffer.
local _toggling = nil

local function find_buf_for_name(name)
  for buf, n in pairs(buf_to_name) do
    if n == name and vim.api.nvim_buf_is_valid(buf) then
      return buf
    end
  end
end

-- Kill a registered process by name. If ad-hoc, remove from registry.
local function kill(name)
  local buf = find_buf_for_name(name)
  if buf then
    local st = vim.b[buf] and vim.b[buf].snacks_terminal
    local job_id = st and st.id
    if job_id then
      vim.notify("Killing " .. name .. " ...")
      pcall(vim.fn.jobstop, job_id)
    end
    buf_to_name[buf] = nil
    attached_bufs[buf] = nil
    vim.schedule(function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end
  -- Remove ad-hoc entries from registry so they disappear from the picker.
  if name:find("^%[ad-hoc%]") then
    registry[name] = nil
  end
end

-- Kill, clean up, and reopen a registered process by name.
local function restart(name)
  local buf = find_buf_for_name(name)
  if buf then
    local st = vim.b[buf] and vim.b[buf].snacks_terminal
    local job_id = st and st.id
    if job_id then
      pcall(vim.fn.jobstop, job_id)
    end
    buf_to_name[buf] = nil
    attached_bufs[buf] = nil
    vim.schedule(function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      M.toggle(name)
    end)
  else
    M.toggle(name)
  end
end

local term_opts = {
  interactive = false,
  win = {
    position = "float",
    border = "rounded",
    width = 0.8,
    height = 0.8,
    footer_keys = true,
    on_win = function(self)
      local buf = self.buf
      vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(buf), 0 })
      if _toggling then
        buf_to_name[buf] = _toggling
      end
      if not attached_bufs[buf] then
        attached_bufs[buf] = true
        vim.api.nvim_buf_attach(buf, false, {
          on_lines = function(_, b)
            vim.schedule(function()
              if not vim.api.nvim_buf_is_valid(b) then
                return
              end
              local lc = vim.api.nvim_buf_line_count(b)
              for _, w in ipairs(vim.fn.win_findbuf(b)) do
                pcall(vim.api.nvim_win_set_cursor, w, { lc, 0 })
              end
            end)
          end,
        })
      end
    end,
    keys = {
      {
        "q",
        function(self)
          self:hide()
        end,
        mode = "n",
        desc = "close",
      },
      {
        "<C-r>",
        function(self)
          local name = buf_to_name[self.buf]
          if not name then
            return
          end
          self:hide()
          restart(name)
        end,
        mode = "n",
        desc = "↺ restart",
      },
      {
        "<C-x>",
        function(self)
          local name = buf_to_name[self.buf]
          if not name then
            return
          end
          self:hide()
          kill(name)
        end,
        mode = "n",
        desc = "✕ kill",
      },
    },
  },
}

local function resolve(cmd)
  return type(cmd) == "function" and cmd() or cmd
end

function M.register(name, cmd, opts)
  if not cmd then
    return
  end
  registry[name] = { cmd = cmd, desc = opts and opts.desc, on_open = opts and opts.on_open }
end

function M.toggle(name)
  local entry = registry[name]
  if not entry then
    vim.notify("procs: no command registered for '" .. name .. "'", vim.log.levels.WARN)
    return
  end
  local cmd = resolve(entry.cmd)
  if not cmd or cmd == "" then
    vim.notify("procs: command for '" .. name .. "' resolved to empty", vim.log.levels.WARN)
    return
  end
  _toggling = name
  require("snacks").terminal.toggle(cmd, term_opts)
  _toggling = nil
  if entry.on_open and not entry._opened then
    entry._opened = true
    vim.schedule(entry.on_open)
  end
end

function M.prompt_new()
  -- on_win fires after open_win (window exists + is current); scheduling startinsert
  -- from here runs after snacks' own nvim_win_call(startinsert!) and its restore,
  -- so we always land in insert mode regardless of what nvim_win_call does.
  require("snacks.input")({
    prompt = "command: ",
    win = {
      row = -3,
      on_win = function()
        vim.schedule(vim.cmd.startinsert)
      end,
    },
  }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    input = vim.trim(input)
    local name = "[ad-hoc] " .. input
    M.register(name, input, { desc = "ad-hoc" })
    M.toggle(name)
  end)
end

local function make_previewer()
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
      { "ErrorMsg", [[\c\<\(error\|fatal\|fail\(ed\)\?\|panic\)\>]] },
      { "WarningMsg", [[\c\<warn\(ing\)\?\>]] },
      { "DiagnosticOk", [[\c\<\(ok\|pass\(ed\)\?\|success\(ful\)\?\)\>]] },
      { "Comment", [[\c\<debug\>]] },
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
    local e = entry.value
    local lines = {}
    if e.desc and e.desc ~= "" then
      vim.list_extend(lines, vim.split(e.desc, "\n"))
      table.insert(lines, "")
    end
    table.insert(lines, "$ " .. e.cmd)
    table.insert(lines, string.rep("─", 40))
    local term_buf = find_buf_for_name(e.name)
    if term_buf then
      vim.list_extend(lines, vim.api.nvim_buf_get_lines(term_buf, 0, -1, false))
    else
      table.insert(lines, "(not running — <enter> to start)")
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
  local entries = {}
  for name, e in pairs(registry) do
    local cmd = type(e.cmd) == "function" and "(dynamic)" or e.cmd
    table.insert(entries, { name = name, cmd = cmd, desc = e.desc })
  end
  if #entries == 0 then
    vim.notify("procs: no processes registered", vim.log.levels.INFO)
    return
  end
  table.sort(entries, function(a, b)
    return a.name < b.name
  end)

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "long-running processes  <C-n> ⊕  <C-r> ↺  <C-x> ✕",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          local cmd_snippet = e.cmd:sub(1, 60) .. (e.cmd:len() > 60 and "…" or "")
          local display = string.format("%-30s  %s", e.name, cmd_snippet)
          return { value = e, display = display, ordinal = e.name }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = make_previewer(),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            M.toggle(sel.value.name)
          end
        end)
        local function new_adhoc()
          actions.close(prompt_bufnr)
          M.prompt_new()
        end
        local function do_restart()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            restart(sel.value.name)
          end
        end
        map("i", "<C-n>", new_adhoc)
        map("n", "<C-n>", new_adhoc)
        map("i", "<C-r>", do_restart)
        map("n", "<C-r>", do_restart)
        local function do_kill()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            kill(sel.value.name)
          end
        end
        map("i", "<C-x>", do_kill)
        map("n", "<C-x>", do_kill)
        return true
      end,
    })
    :find()
end

return M
