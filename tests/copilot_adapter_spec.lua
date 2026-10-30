-- Specs for the copilot adapter: parse_tool_result (edit and create) and session_ownership,
-- including the fallback to the first-line session.start record.

local copilot = require("harness-decorators.copilot")

local tmpdir = vim.fn.tempname() .. "-copilot-adapter"

local function tool_line(tool, args)
  return vim.json.encode({
    type = "tool.execution_start",
    id = "evt-1",
    timestamp = "2025-01-01T00:00:00Z",
    data = { toolName = tool, toolCallId = "call-1", arguments = args },
  })
end

local function start_line(cwd)
  return vim.json.encode({ type = "session.start", data = { context = { cwd = cwd } } })
end

local function write_file(name, lines)
  vim.fn.mkdir(tmpdir, "p")
  local path = tmpdir .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

describe("copilot.parse_tool_result", function()
  it("parses an edit with old_str/new_str into an Edit with a starting_line", function()
    local ci =
      copilot.parse_tool_result(tool_line("edit", { path = "/proj/a.lua", old_str = "a\nb", new_str = "a\nB" }), 7)
    assert.is_not_nil(ci)
    assert.are.equal("/proj/a.lua", ci.file_path)
    assert.are.equal("Edit", ci.operation)
    assert.is_number(ci.starting_line)
    assert.are.equal("copilot-call-1", ci.dedup_key)
    assert.are.equal("call-1", ci.event_id)
    assert.are.equal("evt-1", ci.event_uuid)
    assert.are.equal(7, ci.source_line)
  end)

  it("parses a create into a Create with no starting_line", function()
    local ci = copilot.parse_tool_result(tool_line("create", { path = "/proj/new.lua", content = "x" }), 3)
    assert.is_not_nil(ci)
    assert.are.equal("Create", ci.operation)
    assert.is_nil(ci.starting_line)
    assert.are.equal("/proj/new.lua", ci.file_path)
  end)

  it("returns nil for other tools, other events, noise paths, and bad JSON", function()
    assert.is_nil(copilot.parse_tool_result(tool_line("view", { path = "/proj/a.lua" }), 1))
    assert.is_nil(copilot.parse_tool_result('{"type":"assistant.message"}', 1))
    assert.is_nil(copilot.parse_tool_result(tool_line("edit", { path = "/proj/a.lua.swp", new_str = "x" }), 1))
    assert.is_nil(copilot.parse_tool_result('{"type":"tool.execution_start","edit" nope', 1))
  end)
end)

describe("copilot.session_ownership", function()
  teardown(function()
    vim.fn.delete(tmpdir, "rf")
  end)

  it("is unknown when nvim_cwd is nil", function()
    assert.are.equal("unknown", copilot.session_ownership(nil, { start_line("/a") }, nil))
  end)

  it("matches and mismatches on a session.start line among the lines", function()
    assert.are.equal("match", copilot.session_ownership("/a", { start_line("/a") }, nil))
    assert.are.equal("mismatch", copilot.session_ownership("/a", { start_line("/b") }, nil))
  end)

  it("falls back to the first line of the file when the lines carry no session.start", function()
    local path = write_file("fallback.jsonl", { start_line("/a"), '{"type":"user.message"}' })
    assert.are.equal("match", copilot.session_ownership("/a", { '{"type":"user.message"}' }, path))
    assert.are.equal("mismatch", copilot.session_ownership("/z", { '{"type":"user.message"}' }, path))
  end)

  it("is unknown when neither the lines nor the first line give a cwd", function()
    local path = write_file("nostart.jsonl", { '{"type":"user.message"}' })
    assert.are.equal("unknown", copilot.session_ownership("/a", { '{"type":"user.message"}' }, path))
    assert.are.equal("unknown", copilot.session_ownership("/a", {}, nil))
  end)
end)
