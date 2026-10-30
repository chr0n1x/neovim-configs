-- Spec for the cwd term.lua records for a harness: it must be the directory the harness process
-- actually runs in, because the state adapters look up sessions under it. This spawns a real job
-- through the real snacks.terminal and reads its cwd from /proc (Linux only, as in CI).
describe("term: recorded cwd matches the harness's real cwd", function()
  local env_mod = "harness-decorators.maki.env"
  local saved_env

  before_each(function()
    saved_env = package.loaded[env_mod]
    package.loaded[env_mod] = "sleep 30"
  end)

  after_each(function()
    package.loaded[env_mod] = saved_env
    require("harness-decorators.term")._reset()
  end)

  it("Given the current buffer is a file in a subdirectory, When open, Then term.cwd is the job's cwd", function()
    if vim.fn.isdirectory("/proc/self") == 0 then
      pending("needs /proc")
      return
    end
    local term = require("harness-decorators.term")
    term._reset()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = dir .. "/main.lua"
    vim.fn.writefile({ "local x = 1" }, file)
    vim.cmd.edit(vim.fn.fnameescape(file))
    local file_buf = vim.api.nvim_get_current_buf()

    local inst = term.open("maki")
    assert.is_not_nil(inst, "open must return the instance")
    local chan = vim.bo[inst.buf].channel
    local pid = vim.fn.jobpid(chan)
    local real = vim.uv.fs_readlink("/proc/" .. pid .. "/cwd")
    assert.are.equal(real, term.cwd("maki"))

    pcall(vim.fn.jobstop, chan)
    pcall(vim.api.nvim_buf_delete, inst.buf, { force = true })
    pcall(vim.api.nvim_buf_delete, file_buf, { force = true })
  end)
end)
