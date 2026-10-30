-- The one owner of the active harness name. switch is its only writer (init/activate); every other
-- module reads get(). Observers register with subscribe and run on notify after a switch.
-- Leaf module: utils is required lazily inside functions so anything can require this at the top.
local M = {}

local function seed()
  local env = os.getenv("NVIM_LLM_HARNESS")
  if env and vim.tbl_contains(require("harness-decorators.utils").list_harnesses(), env) then
    return env
  end
  return "claude"
end

local current = seed()

---Subscribers in registration order, as a list of { id, fn }.
local subscribers = {}

---@return string the active harness name
function M.get()
  return current
end

---Set the active harness without notifying subscribers.
---@param name string
function M.set(name)
  current = name
end

---Register fn(new, old) under id. Subscribing an existing id replaces its callback in place, so a
---module reload does not register twice or change the order.
---@param id string
---@param fn fun(new: string, old: string)
function M.subscribe(id, fn)
  for _, s in ipairs(subscribers) do
    if s.id == id then
      s.fn = fn
      return
    end
  end
  subscribers[#subscribers + 1] = { id = id, fn = fn }
end

---Run every subscriber in order, each in its own pcall. A failure is logged at WARN and the rest
---still run; the active value is left as is.
---@param new string
---@param old string
---@return string[] ids of the subscribers that failed
function M.notify(new, old)
  local failed = {}
  for _, s in ipairs(subscribers) do
    local ok, err = pcall(s.fn, new, old)
    if not ok then
      failed[#failed + 1] = s.id
      require("harness-decorators.utils").log("activate: " .. s.id .. " failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  return failed
end

function M._reset_for_test()
  current = seed()
  subscribers = {}
end

return M
