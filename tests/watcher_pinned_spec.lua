-- Watcher behavior on the pinned session: reset commands (/clear, /resume, /new) and per-line
-- isolation inside one written chunk. Drives M.process_jsonl_write against a real temp JSONL in
-- the claude dialect, the same way tests/ownership_spec.lua does. A file pins on its second
-- write (the first write only records the read position).

local utils = require("harness-decorators.utils")
local watcher = require("harness-decorators.watcher")
local edit_jump = require("harness-decorators.edit-jump")
local parser = require("harness-decorators.jsonl-parser")

local SID = "aaaa1111"

local function append(path, lines)
  local f = assert(io.open(path, "a"))
  for _, line in ipairs(lines) do
    f:write(line .. "\n")
  end
  f:close()
end

local function header_line(cwd)
  return string.format('{"type":"user","cwd":%q,"sessionId":%q}', cwd, SID)
end

local function command_line(cwd, cmd)
  return string.format('{"type":"user","cwd":%q,"sessionId":%q,"message":{"role":"user","content":%q}}', cwd, SID, cmd)
end

local function edit_line(uuid)
  local fp = vim.uv.cwd() .. "/tests/_watcher_dispatch_target.txt"
  return string.format(
    '{"type":"user","uuid":%q,"timestamp":1700000000000,"toolUseResult":{"filePath":%q,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" a"," b","+ added line"," c"]}]}}',
    uuid,
    fp
  )
end

describe("watcher pinned session", function()
  local tmpdir, path, cwd, group, seen

  before_each(function()
    assert.are.equal("claude", utils.harness, "watcher pinned spec assumes the claude adapter")
    -- Other specs switch harnesses, which reloads the adapter module; point the watcher at claude.
    watcher.set_harness("claude")
    tmpdir = vim.fn.tempname() .. "-pinned"
    vim.fn.mkdir(tmpdir, "p")
    path = tmpdir .. "/" .. SID .. ".jsonl"
    cwd = vim.uv.cwd()
    watcher.nvim_cwd = cwd

    seen = {}
    group = vim.api.nvim_create_augroup("WatcherPinnedSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "HarnessEdit",
      callback = function(args)
        table.insert(seen, args.data)
      end,
    })

    append(path, { header_line(cwd) })
    watcher.process_jsonl_write(path)
    append(path, { header_line(cwd) })
    watcher.process_jsonl_write(path)
    assert.are.equal(path, watcher.pinned_jsonl_path, "precondition: session pinned")
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    watcher.reset_all()
    watcher.nvim_cwd = nil
    vim.fn.delete(tmpdir, "rf")
  end)

  describe("reset commands", function()
    it(
      "Given a pinned session with history, When /clear is typed, Then the pin stays and dedup, history and line positions are cleared",
      function()
        edit_jump.edit_sources[SID] = { { file_path = "/tmp/x" } }
        utils.mark_key_seen("pinned-spec-key")

        append(path, { command_line(cwd, "/clear") })
        watcher.process_jsonl_write(path)

        assert.are.equal(path, watcher.pinned_jsonl_path)
        assert.are.equal(SID, watcher.pinned_session_id)
        assert.is_nil(edit_jump.edit_sources[SID])
        assert.is_false(utils.key_seen("pinned-spec-key"))

        append(path, { edit_line("after-clear") })
        watcher.process_jsonl_write(path)
        assert.are.equal(1, #seen)
        assert.are.equal(1, seen[1].source_line, "line numbering restarts after /clear")
      end
    )

    for _, cmd in ipairs({ "/resume", "/new" }) do
      it(
        "Given a pinned session with history, When "
          .. cmd
          .. " is typed, Then the pin is released and earlier history is kept",
        function()
          edit_jump.edit_sources[SID] = { { file_path = "/tmp/x" } }

          append(path, { command_line(cwd, cmd) })
          watcher.process_jsonl_write(path)

          assert.is_nil(watcher.pinned_jsonl_path)
          assert.is_nil(watcher.pinned_session_id)
          assert.is_not_nil(edit_jump.edit_sources[SID])
        end
      )
    end
  end)

  describe("per-line isolation", function()
    local orig_parse

    before_each(function()
      orig_parse = parser.parse_tool_result
      parser.parse_tool_result = function(line, n)
        if line:find("BOOM", 1, true) then
          error("parser blew up")
        end
        return orig_parse(line, n)
      end
    end)

    after_each(function()
      parser.parse_tool_result = orig_parse
    end)

    it(
      "Given a chunk whose second line makes the parser throw, When the chunk is processed, Then the first and third lines still dispatch",
      function()
        append(path, { edit_line("iso-1"), '{"BOOM":1}', edit_line("iso-3") })
        pcall(watcher.process_jsonl_write, path)

        local uuids = {}
        for _, d in ipairs(seen) do
          uuids[#uuids + 1] = d.event_uuid
        end
        assert.are.same({ "iso-1", "iso-3" }, uuids)
      end
    )
  end)
end)
