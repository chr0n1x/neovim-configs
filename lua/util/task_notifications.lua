-- https://github.com/rcarriga/nvim-notify/issues/71

local spinner_frames = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }

local M = { cache = {} }

local function update_spinner(task_name)
  if M.cache[task_name] == nil then
    return
  end
  if M.cache[task_name].notification == nil then
    return
  end

  local new_spinner = (M.cache[task_name].spinner + 1) % #spinner_frames
  M.cache[task_name].spinner = new_spinner
  M.cache[task_name].notification = vim.notify(
    M.cache[task_name].msg, nil,
    {
      hide_from_history = true,
      icon = spinner_frames[new_spinner],
      replace = M.cache[task_name].notification,
    }
  )

  vim.defer_fn(function() update_spinner(task_name) end, 64)
end

function M.clear(task_name, icon)
  if M.cache[task_name].notification == nil then
    return
  end

  icon = icon or ""

  vim.notify(
    M.cache[task_name].msg, vim.log.levels.INFO,
    {
      title = task_name,
      icon = icon,
      timeout= 1500,
      hide_from_history = false,
      replace = M.cache[task_name].notification,
    }
  )

  M.cache[task_name] = {}
end

function M.start(task_name, msg)
  M.cache[task_name] = M.cache[task_name] or {}

  -- clear out everything before setting any defaults
  if not M.cache[task_name].notification == nil then
    M.clear_notification(task_name, "")
  end

  M.cache[task_name].spinner = 1
  M.cache[task_name].msg = msg
  M.cache[task_name].notification = vim.notify(
    msg,
    vim.log.levels.INFO,
    {
      title = task_name,
      icon = spinner_frames[1],
      timeout = false,
      hide_from_history = true,
    }
  )
  require('plenary.async').run(function() update_spinner(task_name) end)
end

return M
