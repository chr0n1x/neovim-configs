-- Watcher behavior on the pinned session: reset commands (/clear, /resume, /new) and per-line
-- isolation inside one written chunk. Drives M.process_jsonl_write against a real temp JSONL in
-- the claude dialect, the same way tests/ownership_spec.lua does. A file pins on its second
-- write (the first write only records the read position).

local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")
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
    assert.are.equal("claude", active.get(), "watcher pinned spec assumes the claude adapter")
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

  describe("sidecar round trip", function()
    local orig_stdpath, cache

    before_each(function()
      cache = tmpdir .. "/cache"
      orig_stdpath = vim.fn.stdpath
      vim.fn.stdpath = function(what)
        if what == "cache" then
          return cache
        end
        return orig_stdpath(what)
      end
    end)

    after_each(function()
      vim.fn.stdpath = orig_stdpath
    end)

    it(
      "Given the sidecar directory cannot be created, When a valid edit line is processed, Then HarnessEdit still fires",
      function()
        local orig_mkdir = vim.fn.mkdir
        vim.fn.mkdir = function()
          error("E739: Cannot create directory")
        end
        append(path, { edit_line("nodir-1") })
        local ok, err = pcall(watcher.process_jsonl_write, path)
        vim.fn.mkdir = orig_mkdir
        assert.is_true(ok, tostring(err))
        assert.are.equal(1, #seen)
        assert.are.equal("nodir-1", seen[1].event_uuid)
      end
    )

    it(
      "Given a watcher edit stored by edit-jump, When its record is previewed, Then the real sidecar lookup renders its diff",
      function()
        local jump_group = vim.api.nvim_create_augroup("WatcherPinnedRoundTripSpec", { clear = true })
        edit_jump.create_jump_autocmds(jump_group)
        append(path, { edit_line("rt-1") })
        watcher.process_jsonl_write(path)
        pcall(vim.api.nvim_del_augroup_by_id, jump_group)

        local records = edit_jump.edit_sources[SID]
        assert.is_not_nil(records, "edit-jump stored a record for the pinned session")
        local record = records[#records]
        assert.are.equal("rt-1", record.event_uuid)
        assert.are.equal(cache .. "/harness/", record.sidecar_path:sub(1, #cache + #"/harness/"))
        local sidecar = require("harness-decorators.sidecar")
        local ev = sidecar.lookup(record.sidecar_path, record.event_uuid, record.event_timestamp, record.event_id)
        assert.is_not_nil(ev, "the record's sidecar holds the event")
        assert.is_truthy(sidecar.extract_diff(ev):find("added line", 1, true))
      end
    )
  end)

  describe("HarnessEdit handler errors", function()
    local orig_log, logs, throw_group

    before_each(function()
      logs = {}
      orig_log = utils.log
      utils.log = function(msg, level)
        logs[#logs + 1] = { msg = tostring(msg), level = level }
      end
      throw_group = vim.api.nvim_create_augroup("WatcherPinnedThrowSpec", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = throw_group,
        pattern = "HarnessEdit",
        callback = function(args)
          if args.data.event_uuid == "throw-1" then
            error("handler blew up")
          end
        end,
      })
    end)

    after_each(function()
      utils.log = orig_log
      pcall(vim.api.nvim_del_augroup_by_id, throw_group)
    end)

    it(
      "Given a HarnessEdit handler that throws on a valid line, When the chunk is processed, Then nvim reports the error, it is not logged as a skipped JSONL line, and the next line still dispatches",
      function()
        append(path, { edit_line("throw-1"), edit_line("after-1") })
        watcher.process_jsonl_write(path)

        for _, l in ipairs(logs) do
          assert.is_nil(l.msg:find("skipping JSONL line", 1, true), "a handler error is not a skipped JSONL line")
        end
        local uuids = {}
        for _, d in ipairs(seen) do
          uuids[#uuids + 1] = d.event_uuid
        end
        assert.are.same({ "throw-1", "after-1" }, uuids)
      end
    )

    it(
      "Given dispatching a parsed line throws, When the chunk is processed, Then the error reaches the caller instead of a skipped-line WARN",
      function()
        local sidecar = require("harness-decorators.sidecar")
        local orig_append = sidecar.append
        sidecar.append = function()
          error("sidecar write failed")
        end
        append(path, { edit_line("side-1") })
        local ok, err = pcall(watcher.process_jsonl_write, path)
        sidecar.append = orig_append

        assert.is_false(ok, "the dispatch error must surface")
        assert.is_truthy(tostring(err):find("sidecar write failed", 1, true))
        for _, l in ipairs(logs) do
          assert.is_nil(l.msg:find("skipping JSONL line", 1, true), "a dispatch error is not a skipped JSONL line")
        end
      end
    )
  end)
end)
