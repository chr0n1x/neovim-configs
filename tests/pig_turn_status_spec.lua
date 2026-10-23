-- pig reads working/idle from the last message entry in the newest session file.

describe("pig state status (turn_status from session file)", function()
  local old_home, home, cwd, sessions

  local function write_session(lines)
    vim.fn.writefile(lines, sessions .. "/2026-01-01T00-00-00_abcd1234.jsonl")
  end

  local function msg(role, stop)
    return vim.json.encode({ type = "message", message = { role = role, stopReason = stop } })
  end

  local function status()
    package.loaded["harness-decorators.pig.state"] = nil
    return require("harness-decorators.pig.state").status(0, cwd)
  end

  before_each(function()
    old_home = os.getenv("HOME")
    home = vim.fn.tempname()
    cwd = "/work/proj"
    sessions = home .. "/.pig/agent/sessions/--work-proj--"
    vim.fn.mkdir(sessions, "p")
    vim.fn.setenv("HOME", home)
  end)

  after_each(function()
    vim.fn.setenv("HOME", old_home)
  end)

  it("is idle when the last message is an assistant that stopped", function()
    write_session({ msg("user"), msg("assistant", "stop") })
    assert.are.equal("idle", status())
  end)

  it("is working for a trailing user message", function()
    write_session({ msg("assistant", "stop"), msg("user") })
    assert.are.equal("working", status())
  end)

  it("is working when the assistant stopped on toolUse", function()
    write_session({ msg("assistant", "toolUse") })
    assert.are.equal("working", status())
  end)

  it("last message wins and non-message or garbage lines are skipped", function()
    write_session({ msg("user"), "not json", vim.json.encode({ type = "other" }) })
    assert.are.equal("working", status())
  end)

  it("is unknown when there is no message entry", function()
    write_session({ vim.json.encode({ type = "session" }) })
    assert.are.equal("unknown", status())
  end)
end)
