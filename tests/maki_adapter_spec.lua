-- Specs for the maki adapter: on_pin (base offset for a mid-line start, no newline in the
-- tail, a small file) and session_ownership via the header line.

local maki = require("harness-decorators.maki")
local watcher = require("harness-decorators.watcher")

local tmpdir = vim.fn.tempname() .. "-maki-adapter"
local TAIL = 16384

local function write_raw(name, content)
  vim.fn.mkdir(tmpdir, "p")
  local path = tmpdir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

local function header(cwd)
  return vim.json.encode({ t = "header", id = "sess-1", cwd = cwd })
end

describe("maki.on_pin", function()
  local orig, recovered

  before_each(function()
    orig = watcher.process_recovered_lines
    recovered = nil
    watcher.process_recovered_lines = function(lines, offset)
      recovered = { lines = lines, offset = offset }
    end
  end)

  after_each(function()
    watcher.process_recovered_lines = orig
  end)

  teardown(function()
    vim.fn.delete(tmpdir, "rf")
  end)

  it("returns 0 and feeds every line for a file smaller than the tail", function()
    local content = "line-one\nline-two\nline-three\n"
    local path = write_raw("small.jsonl", content)
    assert.are.equal(0, maki.on_pin(path, #content))
    assert.are.same({ "line-one", "line-two", "line-three" }, recovered.lines)
    assert.are.equal(-3, recovered.offset)
  end)

  it("skips the partial first line of a mid-line start and returns the offset after it", function()
    local first = string.rep("x", 100) .. "\n"
    local filler = string.rep("y", TAIL + 50) .. "\n"
    local content = first .. filler .. "tail-a\ntail-b\n"
    local path = write_raw("big.jsonl", content)
    local size = #content
    local start = size - TAIL
    local nl = content:find("\n", start + 1, true)
    local base = maki.on_pin(path, size)
    assert.are.equal(nl, base)
    assert.are.same({ "tail-a", "tail-b" }, recovered.lines)
  end)

  it("returns file_size and dispatches nothing when the tail holds no newline", function()
    local content = string.rep("z", TAIL * 2)
    local path = write_raw("nonl.jsonl", content)
    assert.are.equal(#content, maki.on_pin(path, #content))
    assert.is_nil(recovered)
  end)

  it("decides from the watcher's file_size when the file grew after it was measured", function()
    local content = string.rep("z", TAIL * 2)
    local path = write_raw("grown.jsonl", content)
    assert.are.equal(#content - 100, maki.on_pin(path, #content - 100))
    assert.is_nil(recovered)
  end)

  it("returns file_size for an unreadable path", function()
    assert.are.equal(42, maki.on_pin(tmpdir .. "/missing.jsonl", 42))
    assert.is_nil(recovered)
  end)
end)

describe("maki.session_ownership", function()
  teardown(function()
    vim.fn.delete(tmpdir, "rf")
  end)

  it("is unknown when nvim_cwd is nil", function()
    assert.are.equal("unknown", maki.session_ownership(nil, { header("/a") }, nil))
  end)

  it("reads the header line among the lines", function()
    assert.are.equal("match", maki.session_ownership("/a", { header("/a") }, nil))
    assert.are.equal("mismatch", maki.session_ownership("/a", { header("/b") }, nil))
  end)

  it("falls back to the header at the top of the file when the lines have none", function()
    local path = write_raw("hdr.jsonl", header("/a") .. '\n{"t":"msg"}\n')
    assert.are.equal("match", maki.session_ownership("/a", { '{"t":"msg"}' }, path))
    assert.are.equal("mismatch", maki.session_ownership("/z", { '{"t":"msg"}' }, path))
  end)

  it("is unknown when the header is unreadable", function()
    local path = write_raw("bad.jsonl", "not json\n")
    assert.are.equal("unknown", maki.session_ownership("/a", {}, path))
    assert.are.equal("unknown", maki.session_ownership("/a", {}, nil))
  end)
end)
