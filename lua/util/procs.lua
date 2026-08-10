local M = {}

-- registry: name -> { cmd, desc }
local registry = {}

local term_opts = {
  interactive = false,
  win = {
    position = "float",
    border = "rounded",
    footer_keys = true,
    on_win = function(self)
      vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(self.buf), 0 })
    end,
  },
}

-- cmd may be a string or a function() -> string (resolved at toggle time).
-- opts: { desc? = string shown in telescope preview }
function M.register(name, cmd, opts)
  if not cmd then
    return
  end
  registry[name] = { cmd = cmd, desc = opts and opts.desc }
end

local function resolve(cmd)
  return type(cmd) == "function" and cmd() or cmd
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
  require("snacks").terminal.toggle(cmd, term_opts)
end

local function make_previewer()
  local previewers = require("telescope.previewers")
  return previewers.new_buffer_previewer({
    title = "details",
    define_preview = function(self, entry)
      local e = entry.value
      local lines = {}
      if e.desc and e.desc ~= "" then
        for _, line in ipairs(vim.split(e.desc, "\n")) do
          table.insert(lines, line)
        end
        table.insert(lines, "")
      end
      table.insert(lines, "command:")
      for _, segment in ipairs(vim.split(e.cmd, " %-")) do
        table.insert(lines, "  " .. (segment == e.cmd and segment or "-" .. segment))
      end
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
    end,
  })
end

function M.pick()
  local entries = {}
  for name, e in pairs(registry) do
    table.insert(entries, { name = name, cmd = resolve(e.cmd), desc = e.desc })
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
      prompt_title = "long-running processes",
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
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            M.toggle(sel.value.name)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
