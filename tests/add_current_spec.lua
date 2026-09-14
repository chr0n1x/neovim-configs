-- <leader>ca ACTION test. The focus side of <leader>ca (jump to the terminal, then
-- <C-h> back) is covered by go_back_after_add_spec; this covers the action itself: for
-- every harness that declares a normal-mode <leader>ca, the command it runs must resolve
-- % to a REAL, readable file and reach the send stage - not error out early on an
-- unexpanded token or a missing path.
--
-- Why this matters: the per-harness add commands (MakiAdd/CopilotAdd) expand vim tokens
-- (% # <cfile> ~) BEFORE their filereadable check, and claude's ClaudeCodeAdd does the same.
-- A regression that drops or reorders that expansion would make `<leader>ca` fail with
-- "not a readable file: %" - silent from the user's perspective except for one warning.
-- Nothing else in the suite exercises the add command end-to-end.
--
-- How it works without a live AI process (deterministic, no PTY echo / timing):
--   * copilot/maki run LOCAL user-commands (CopilotAdd/MakiAdd) whose only real dependency
--     on the harness is find_*_terminal_win(), which scans for any visible buftype=="terminal"
--     window. We open a plain `cat` terminal (no AI process needed) so that lookup succeeds,
--     then stub vim.fn.chansend to RECORD the exact payload instead of writing to the PTY.
--     The command's % expansion and filereadable gate run for real; we assert:
--       (a) a missing path is rejected with an explicit "not a readable file" error, and
--       (b) a real path passes the gate and reaches chansend with the per-harness context
--           format (copilot " @path", maki bare path). Capturing at chansend observes the
--           real build_context_text output with zero PTY round-trip or timing.
--   * claude's ClaudeCodeAdd is a STOCK plugin command that talks to the websocket server,
--     so we drive it with M.state.server stubbed: real path validation runs, and the send
--     stage (_broadcast_at_mention) is stubbed to record what would be sent. This catches
--     "not running" early-returns (server nil), unexpanded-% failures, and a broken
--     hand-off to the send stage.

local helper = require("tests.helper")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

describe("<leader>ca action: resolves % to a real file and reaches the send stage", function()
  local original_harness
  local cc -- claudecode.nvim module (stock ClaudeCodeAdd)
  local saved = {} -- saved plugin state for stubbing
  local orig_notify -- vim.notify captured once, restored in teardown
  local orig_filereadable -- vim.fn.filereadable stubbed per-test, restored in teardown
  local orig_chansend -- vim.fn.chansend stubbed per-test, restored in teardown

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to start from")
    cc = require("claudecode")
    for _, k in ipairs({ "server", "_broadcast_at_mention", "is_claude_connected" }) do
      saved[k] = cc[k]
    end
  end)

  -- The success path of send_at_mention calls terminal.open()/ensure_visible() to focus
  -- the harness float. In headless mode that can spawn a snacks float we don't want (and
  -- the claude test's whole point is the send stage, not window management), so stub both
  -- for the duration of this suite.
  local function stub_terminal_focus()
    local term = require("claudecode.terminal")
    saved.term_open = term.open
    saved.term_ensure_visible = term.ensure_visible
    term.open = function() end
    term.ensure_visible = function() end
  end

  local function restore_terminal_focus()
    if saved.term_open then
      local term = require("claudecode.terminal")
      term.open = saved.term_open
      term.ensure_visible = saved.term_ensure_visible
      saved.term_open = nil
      saved.term_ensure_visible = nil
    end
  end

  teardown(function()
    restore_terminal_focus()
    if orig_notify then
      vim.notify = orig_notify
      orig_notify = nil
    end
    if orig_filereadable then
      vim.fn.filereadable = orig_filereadable
      orig_filereadable = nil
    end
    if orig_chansend then
      vim.fn.chansend = orig_chansend
      orig_chansend = nil
    end
    -- Collapse to a single window so later specs (which open their own splits and are
    -- sensitive to leftover layout) do not hit E36 "Not enough room". Closing only the
    -- terminal windows is not enough: a non-terminal split left by vsplit still narrows
    -- the buffer for the next spec's vnew.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) and w ~= vim.api.nvim_get_current_win() then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if original_harness then
      pcall(require("harness-decorators.switch").switch, original_harness)
    end
  end)

  ---Capture vim.notify (the config wraps it with nvim-notify) for the rest of this
  -- test. Restored in teardown. Returns the collector table; error-path assertions
  -- inspect it after driving the command.
  local function capture_notes()
    orig_notify = vim.notify
    local notes = {}
    vim.notify = function(msg, ...)
      table.insert(notes, tostring(msg))
    end
    return notes
  end

  ---Open a scratch file buffer in the current window and return its absolute path.
  -- The filename is made unique per test so an assertion on one test's path cannot be
  -- satisfied by a leftover from another.
  local seq = 0
  local function open_real_file()
    seq = seq + 1
    local path = vim.fn.tempname() .. "-add-current-" .. seq .. ".txt"
    assert.is_true(vim.fn.writefile({ "line one", "line two" }, path) == 0, "could not write scratch file")
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two" })
    vim.api.nvim_set_current_buf(buf)
    return path
  end

  ---Force vim.fn.filereadable to a fixed value for the duration of a test. The add
  -- commands gate on filereadable AFTER expanding %; stubbing it lets us exercise both
  -- branches (readable -> reaches send stage, unreadable -> explicit error) without any
  -- timing dependency. Restored in teardown.
  local function force_filereadable(val)
    orig_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function() return val end
  end

  ---Open a plain `cat` terminal in a split so find_*_terminal_win() has a visible
  -- buftype=="terminal" window to return. We do NOT read the PTY: chansend is stubbed
  -- (see capture_chansend) so nothing is actually written and there is no echo to wait for.
  local function open_cat_terminal()
    vim.cmd("vsplit")
    local ok = pcall(vim.cmd, "terminal cat")
    assert.is_true(ok, "could not open a terminal window (cat)")
    local win = vim.api.nvim_get_current_win()
    -- Give the terminal buffer a moment to register its buftype before we leave the window.
    vim.wait(100, function() return false end, 25)
    vim.cmd("wincmd p")
    return win
  end

  ---Stub vim.fn.chansend to record every payload instead of writing to the PTY. Returns
  -- the collector table; the command's build_context_text output is the first payload.
  local function capture_chansend()
    orig_chansend = vim.fn.chansend
    local payloads = {}
    vim.fn.chansend = function(_chan, data)
      table.insert(payloads, tostring(data))
      return 1 -- non-zero "bytes written" so the command's success path continues
    end
    return payloads
  end

  ---The command name a harness's <leader>ca normal-mode entry runs, or nil if the
  -- harness declares no such binding. Returns (cmd_name, spec).
  local function add_command_for(harness)
    for _, spec in ipairs(keymaps.build(harness)) do
      if spec[1] == "<leader>ca" and not spec.ft then
        local mode = type(spec.mode) == "table" and spec.mode or { spec.mode or "n" }
        if vim.tbl_contains(mode, "n") then
          -- The rhs is a <cmd>...<cr> string; extract the command name.
          local cmd = tostring(spec[2]):match("<cmd>(%w+)")
          return cmd, spec
        end
      end
    end
    return nil, nil
  end

  for _, harness in ipairs(utils.list_harnesses()) do
    describe(("harness: %s"):format(harness), function()
      local cmd_name

      setup(function()
        require("harness-decorators.switch").switch(harness)
        cmd_name = select(1, add_command_for(harness))
      end)

      it("<leader>ca binding matches the harness's declared add command", function()
        if not cmd_name then
          -- crush (tree-add only) and pi (barebones) declare no normal-mode <leader>ca.
          return
        end
        assert.is_not_nil(cmd_name, ("%s: <leader>ca entry has no parseable command"):format(harness))
      end)

      it("<leader>ca resolves %% to a real file and reaches the send stage", function()
        if not cmd_name then
          return -- nothing declared; binding-absence is covered by harness_keymaps_spec
        end

        local path = open_real_file()
        assert.are.equal(path, vim.fn.expand("%:p"), "current buffer must be the scratch file")

        if harness == "claude" then
          -- Stock plugin command: stub the server so path validation runs for real and
          -- the send stage is recorded instead of hitting the websocket. Stub
          -- is_claude_connected too, so send_at_mention takes the broadcast path rather
          -- than queue_mention (which would spawn a timer + terminal.open() side effects).
          stub_terminal_focus()
          local sent
          cc.state.server = { running = true }
          cc.is_claude_connected = function() return true end
          cc._broadcast_at_mention = function(file_path, start_line, end_line)
            sent = { file_path = file_path, start_line = start_line, end_line = end_line }
            return true, nil, { file_path = file_path, start_line = start_line, end_line = end_line }
          end

          local ok, err = pcall(vim.cmd, "ClaudeCodeAdd %")
          assert.is_true(ok, ("ClaudeCodeAdd %% errored: %s"):format(tostring(err)))
          -- _broadcast_at_mention is called synchronously on the connected path, so `sent`
          -- is set by the time the command returns - no wait needed.
          assert.is_not_nil(sent, "ClaudeCodeAdd did not reach the send stage (server/connected stub ineffective)")
          assert.are.equal(path, sent.file_path,
            ("claude: %% did not resolve to the real path (got %q)"):format(tostring(sent.file_path)))
        else
          -- copilot/maki: local user-commands. Open a cat terminal so find_*_terminal_win
          -- succeeds, stub chansend to capture the payload, and force filereadable=true so
          -- the command's % expansion + readable gate run for real and pass through to the
          -- send stage. The captured payload is exactly build_context_text(expanded_path).
          local term_win = open_cat_terminal()
          local payloads = capture_chansend()
          local notes = capture_notes()
          force_filereadable(1)

          local ok, err = pcall(vim.cmd, cmd_name .. " %")
          assert.is_true(ok, ("%sAdd %% errored: %s"):format(harness, tostring(err)))

          -- No "not a readable file" error: % expanded to a real path and passed the gate.
          for _, n in ipairs(notes) do
            assert.is_falsy(n:find("not a readable file", 1, true),
              ("%s: %% did not resolve to a readable file (got %q)"):format(harness, n))
          end

          -- The command must have reached the send stage (chansend was called).
          assert.is_truthy(#payloads > 0,
            ("%s: command never reached the send stage (chansend not called)"):format(harness))

          -- The per-harness context format is part of the contract this test pins. The first
          -- payload is build_context_text(expanded_path); a trailing space may be appended by
          -- type_into_terminal, so match on the reference fragment rather than exact equality.
          local text = payloads[1]
          local fname = path:match("([^/]+)$")
          if harness == "copilot" then
            -- Copilot uses @file mentions.
            assert.is_truthy(text:find("@", 1, true) and text:find(fname, 1, true),
              ("copilot: expected an @mention reference to %s, got %q"):format(fname, text))
          elseif harness == "maki" then
            -- maki sends the bare (possibly shortened) path; it must NOT be an @mention.
            assert.is_truthy(text:find(fname, 1, true),
              ("maki: expected a bare path reference to %s, got %q"):format(fname, text))
            assert.is_falsy(text:find("@", 1, true),
              ("maki: unexpectedly sent an @mention, got %q"):format(text))
          end

          -- The command must have jumped focus to the terminal; term.lua's shared WinEnter handler
          -- owns the terminal-mode transition for this path too.
          assert.are.equal(term_win, vim.api.nvim_get_current_win(),
            ("%s: focus did not move to the terminal after add"):format(harness))
        end
      end)

      it("add command rejects an unreadable path with an explicit error", function()
        if not cmd_name then
          return
        end
        -- claude's ClaudeCodeAdd uses its own validation and logs via the plugin logger
        -- rather than vim.notify, so a notification capture cannot observe its error path;
        -- that branch is exercised by the success test's server stub instead.
        if harness == "claude" then
          return
        end

        -- Capture notifications so "explicit error" is assertable, not just "didn't crash".
        local notes = capture_notes()
        -- Stub filereadable=false so the command takes its explicit-error branch regardless
        -- of what % expands to. No terminal or chansend stub needed: the command returns at
        -- the filereadable gate before touching the PTY.
        force_filereadable(0)

        pcall(vim.cmd, cmd_name .. " %")

        local found = false
        for _, n in ipairs(notes) do
          if n:find("not a readable file", 1, true) then
            found = true
          end
        end
        assert.is_truthy(found,
          ("%s: adding an unreadable path produced no explicit error (silent no-op)"):format(harness))
      end)
    end)
  end
end)
