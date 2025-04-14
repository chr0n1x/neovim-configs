-- most of this was from this https://github.com/rcarriga/nvim-notify/issues/71
-- retrofitted
-- spinner frames from https://github.com/ryanoasis/nerd-fonts/blob/master/assets/Mononoki/Mononoki%20Regular%20Nerd%20Font%20Complete.ttf
local spinner_frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local async = require("plenary.async")

local M = { cache = {} }
local notif_style = "wrapped-compact"


local function log_icon(level)
  if level == vim.log.levels.ERROR then
    return ""
  elseif level == vim.log.levels.WARN then
    return ""
  elseif level == vim.log.levels.DEBUG then
    return "🐛"
  end
  return ""
end


local function update_spinner(task_name, curr_wait_defer)
  curr_wait_defer = curr_wait_defer or 0
  if curr_wait_defer >= 8000 then
    M.clear(task_name, vim.log.levels.WARN)
    return
  end
  curr_wait_defer = curr_wait_defer + 100

  if M.cache[task_name] == nil then
    return
  end

  local new_spinner = (M.cache[task_name].spinner + 1) % #spinner_frames
  M.cache[task_name].spinner = new_spinner
  local updated_notif_opts = {
    hide_from_history = true,
    icon = spinner_frames[new_spinner],
    render = notif_style,
  }

  if M.cache[task_name].notification ~= nil then
    updated_notif_opts.replace = M.cache[task_name].notification
  end

  M.cache[task_name].notification = vim.notify(
    M.cache[task_name].msg, nil, updated_notif_opts
  )

  vim.defer_fn(
    function() update_spinner(task_name, curr_wait_defer) end,
    64
  )
end


function M.clear(task_name, log_level)
  if M.cache[task_name] == nil then
    return
  end

  local clear_notification_opts = {
    title = task_name,
    icon = log_icon(log_level),
    render = notif_style,
    timeout = 1000,
    hide_from_history = false,
  }

  if M.cache[task_name].notification ~= nil then
    clear_notification_opts.replace =
      M.cache[task_name].notification
  end

  vim.notify(
    M.cache[task_name].msg, vim.log.levels.INFO,
    clear_notification_opts
  )

  M.cache[task_name] = nil
end


function M.start(task_name, msg)
  M.cache[task_name] = M.cache[task_name] or {}
  M.cache[task_name].spinner = 1
  M.cache[task_name].msg = msg
  M.cache[task_name].notification = vim.notify(
    msg,
    vim.log.levels.INFO,
    {
      title = task_name,
      icon = spinner_frames[1],
      render = notif_style,
      timeout = false,
      hide_from_history = true,
    }
  )
  async.run(function() update_spinner(task_name) end)
end


return M
