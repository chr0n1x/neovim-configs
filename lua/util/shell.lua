RUN_SHELL_CMD = function(shcmd)
  local handle = io.popen(shcmd)
  if handle == nil then
    return "", 1
  end

  local result = handle:read("*a")
  handle:close()
  return result
end
