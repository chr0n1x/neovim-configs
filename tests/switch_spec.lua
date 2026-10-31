-- Spec for switch.lua.
--
-- The core behavior: switching must BACKGROUND the outgoing harness's terminal (its OWN float stays
-- open and the PTY alive, so it keeps executing, but it is no longer the active harness) and record
-- it for resume - not kill it. The terminal layer is term.lua (one Snacks float per harness), so this
-- spec drives it by opening a fake per-harness instance via term.open (Snacks.terminal.open stubbed
-- to return a windowless-buffer fake). The assertions: after M.switch, the outgoing harness's buffer
-- is still valid AND present in the park table (not deleted), and the watcher follows the NEW active
-- harness. Headless nvim can't drive a real snacks terminal, so the fakes stand in for the floats.

local helper = require("tests.helper")
local sw = require("harness-decorators.switch")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")
local active = require("harness-decorators.active")

describe("switch: backgrounds (parks) instead of kills", function()
  local original_harness
  local orig_env
  local target
  local term_mod
  local snacks
  local orig_open
  local park
  local orig_notify
  local notes

  ---A fake Snacks instance backed by a windowless buffer.
  local function make_fake(buf)
    return {
      buf = buf,
      win = nil,
      hide = function() end,
      show = function() end,
      focus = function() end,
      close = function() end,
      buf_valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
    }
  end

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to switch from")
    orig_env = os.getenv("NVIM_LLM_HARNESS")

    target = nil
    for _, h in ipairs(utils.list_harnesses()) do
      if h ~= original_harness then
        target = h
        break
      end
    end
    assert.is_not_nil(target, "no alternate harness to switch to")

    park = require("harness-decorators.park")
    term_mod = require("harness-decorators.term")
    snacks = require("snacks.terminal")
    orig_open = snacks.open
    -- Stub open so a foreground does not spawn a real terminal in headless; each call returns a fresh
    -- windowless-buffer fake (so two harnesses get two distinct buffers).
    snacks.open = function()
      return make_fake(vim.api.nvim_create_buf(false, true))
    end

    -- Capture vim.notify so specs can assert on what a switch reports.
    orig_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = tostring(msg), level = level })
    end
  end)

  teardown(function()
    if orig_notify then
      vim.notify = orig_notify
    end
    if snacks and orig_open then
      snacks.open = orig_open
    end
    require("harness-decorators.state")._reset()
    -- M.switch changed the active harness (env var + active.get() + current_harness + keymaps).
    -- Restore all of it directly rather than calling switch again, which would re-lay out the floats
    -- and notify the watcher - perturbing later specs that assume the config's default harness.
    -- Re-apply the original harness's keymaps so bindings match the restored current_harness.
    if orig_env then
      vim.fn.setenv("NVIM_LLM_HARNESS", orig_env)
    end
    active.set(original_harness)
    sw.init(original_harness)
    keymaps.clear()
    keymaps.apply(keymaps.build(original_harness))
  end)

  it("keeps the outgoing harness's terminal buffer alive and records it in the registry", function()
    -- The outgoing harness "has" a live float open.
    local inst = term_mod.open(original_harness)
    assert.is_not_nil(inst.buf, "open must create an instance with a buffer")

    local ok = pcall(sw.switch, target)
    assert.is_true(ok, "switch() errored")
    assert.are.equal(target, helper.active_harness(), "switch did not take effect")

    -- The core assertion: the outgoing buffer was NOT deleted.
    assert.is_true(
      vim.api.nvim_buf_is_valid(inst.buf),
      "switch deleted the outgoing harness's terminal buffer (it must stay alive)"
    )
    -- And it was recorded so a later re-pick can resume the same process.
    local entries = park.list()
    local found = false
    for _, e in ipairs(entries) do
      if e.harness == original_harness and e.buff_nr == inst.buf then
        found = true
      end
    end
    assert.is_true(found, "outgoing harness was not recorded in the park table")

    -- The watcher follows ONLY the active harness. After switching to `target`, the watcher's active
    -- harness must be `target` (the foregrounded one), NOT the backgrounded `original_harness`.
    assert.are.equal(
      target,
      active.get(),
      "watcher must follow the active (foregrounded) harness, not the backgrounded one"
    )
  end)

  it(
    "Given a live outgoing harness, When switching to another harness, Then no switch notification is shown",
    function()
      sw.init(original_harness)
      term_mod.open(original_harness)
      for i in pairs(notes) do
        notes[i] = nil
      end

      pcall(sw.switch, target)

      local shown = vim.tbl_filter(function(n)
        return n.msg:find("^harness: ") ~= nil
      end, notes)
      assert.are.same(
        {},
        vim.tbl_map(function(n)
          return n.msg
        end, shown)
      )
    end
  )

  it(
    "Given a harness is active, When another harness is activated, Then it becomes active without moving focus or the floats",
    function()
      sw.init(original_harness)
      local real_reset = term_mod.reset_layout
      local resets = 0
      term_mod.reset_layout = function()
        resets = resets + 1
      end
      local win = vim.api.nvim_get_current_win()
      local ok, err = pcall(sw.activate, target)
      term_mod.reset_layout = real_reset
      assert.is_true(ok, tostring(err))
      assert.are.equal(target, sw.current())
      assert.are.equal(target, active.get(), "the watcher must follow the activated harness")
      assert.are.equal(win, vim.api.nvim_get_current_win(), "activate must not move focus")
      assert.are.equal(0, resets, "activate must not re-lay out the floats")
    end
  )

  it("resolves the incoming harness's command from its env module at open time", function()
    -- There is no global terminal_cmd to re-point: term.lua resolves each harness's command from its
    -- env module when its float opens. So after switching to `target`, opening ITS float must spawn
    -- TARGET's command (helper.env_command reads that env.lua).
    local start_harness = original_harness
    sw.init(start_harness)

    pcall(sw.switch, target)

    -- Stub open again to capture the exact command term.open passes to Snacks for the new harness.
    local captured_cmd
    snacks.open = function(cmd)
      captured_cmd = cmd
      return make_fake(vim.api.nvim_create_buf(false, true))
    end
    require("harness-decorators.state")._reset()
    term_mod.open(target)

    assert.are.equal(
      helper.env_command(target),
      captured_cmd,
      "opening " .. target .. "'s float after a switch must use its own env command"
    )
  end)

  it("after_pick opens the newly-selected harness's terminal (picker auto-open)", function()
    -- Selecting a harness in the picker switches to it and opens its terminal too. after_pick is that
    -- callback, so drive it directly: after a switch, M.after_pick must show the selected (incoming)
    -- harness's float - spawning fresh if it has no live instance yet.
    local start_harness = original_harness
    sw.init(start_harness)
    require("harness-decorators.state")._reset()

    pcall(sw.switch, target)
    assert.is_false(term_mod.is_open(target), "precondition: incoming harness not open before after_pick")

    sw.after_pick()

    assert.is_true(term_mod.is_open(target), "after_pick must open the selected harness's terminal")
  end)

  it(
    "Given a harness started from the <C-q> picker, When after_pick runs, Then edit-following is set up like <leader>c does",
    function()
      -- setup_auto_follow registers the HarnessEdit jump autocmds and starts the watcher; after_pick must
      -- call it as <leader>c does, or a harness started from the picker would not follow its edits.
      local decorators = require("harness-decorators")
      local orig_setup = decorators.setup_auto_follow
      local calls = 0
      decorators.setup_auto_follow = function()
        calls = calls + 1
      end
      sw.init(original_harness)
      require("harness-decorators.state")._reset()
      pcall(sw.switch, target)
      sw.after_pick()
      decorators.setup_auto_follow = orig_setup
      assert.is_true(calls > 0, "after_pick must call setup_auto_follow")
    end
  )

  it("waits for Telescope's mapping to return before focusing the terminal", function()
    local called = false
    local original = sw.after_pick
    local original_mode = vim.fn.mode
    local mode_calls = 0
    sw.after_pick = function()
      called = true
    end
    vim.fn.mode = function()
      mode_calls = mode_calls + 1
      return mode_calls < 3 and "no" or "n"
    end

    sw.schedule_after_pick()
    assert.is_false(called, "picker terminal focus must not run inside Telescope's mapping")
    vim.wait(100, function()
      return called
    end, 10)
    vim.fn.mode = original_mode
    assert.is_true(called, "picker terminal focus must run on the next event-loop turn")
    assert.is_true(mode_calls >= 3, "picker terminal focus must wait for ordinary normal mode")

    sw.after_pick = original
  end)

  it(
    "Given zen mode is open, When a new harness is selected, Then focus is on the zen window so zen mode stays open",
    function()
      sw.init(original_harness)
      local zen_view = require("zen-mode.view")
      local real_is_open, real_win = zen_view.is_open, zen_view.win
      local zen_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 20,
        height = 5,
      })
      zen_view.win = zen_win
      zen_view.is_open = function()
        return true
      end
      local ok, err = pcall(sw.switch, target)
      local cur = vim.api.nvim_get_current_win()
      zen_view.is_open, zen_view.win = real_is_open, real_win
      pcall(vim.api.nvim_win_close, zen_win, true)
      assert.is_true(ok, tostring(err))
      assert.are.equal(zen_win, cur, "a normal window getting focus makes zen-mode close itself")
    end
  )

  it(
    "Given harnesses at fullscreen or on the shelf and one minimized, When another harness is selected, Then every shown harness is back in the normal layout with shelf mode off so the grid can tile them, the minimized one keeps its bar, and only the selected one moves to the normal spot",
    function()
      local layout = require("harness-decorators.layout")
      sw.init(original_harness)
      local third
      for _, h in ipairs(utils.list_harnesses()) do
        if h ~= original_harness and h ~= target then
          third = h
          break
        end
      end
      local a = term_mod.open(original_harness)
      local b = term_mod.open(target)
      local c = term_mod.open(third)
      for _, inst in ipairs({ a, b }) do
        inst.opts = { row = 3, col = 12, width = 999, height = 63 }
      end
      layout.set(a, "fullscreen", { shelf_mode = true })
      layout.set(b, "shelved")
      for _, inst in ipairs({ a, b }) do
        inst._saved_config = { auto = false, row_ratio = 0, col_ratio = 0, width_ratio = 1, height_ratio = 1 }
      end
      layout.set(c, "minimized")
      c._pill_win = vim.api.nvim_open_win(
        vim.api.nvim_create_buf(false, true),
        false,
        { relative = "editor", row = 0, col = 0, width = 10, height = 1 }
      )
      local pill = c._pill_win

      local ok, err = pcall(sw.switch, target)
      local bar_ok = vim.api.nvim_win_is_valid(pill)
      pcall(vim.api.nvim_win_close, pill, true)
      assert.is_true(ok, tostring(err))
      assert.are.equal("normal", layout.get(b), "the selected harness must leave the shelf")
      assert.is_false(b._shelf_mode == true, "the selected harness must leave shelf mode")
      assert.is_nil(b._saved_config, "the selected harness must forget its pre-fullscreen geometry")
      assert.are_not.equal(999, b.opts.width, "the selected harness must restore to the normal spot")
      assert.are.equal("normal", layout.get(a), "the other harness must leave fullscreen to join the grid")
      assert.is_false(a._shelf_mode == true, "the other harness must leave shelf mode to join the grid")
      assert.is_nil(a._saved_config, "the other harness must forget its pre-fullscreen geometry")
      assert.are.equal(999, a.opts.width, "only the selected harness is moved to the normal spot")
      assert.are.equal("minimized", layout.get(c), "a minimized harness stays minimized")
      assert.is_true(bar_ok, "a minimized harness keeps its bar")
    end
  )
end)

describe("switch activation failure boundaries", function()
  local watcher = require("harness-decorators.watcher")
  local state = require("harness-decorators.state")
  local saved, steps, notes
  local modules = {
    "harness-decorators.pi",
    "harness-decorators.pi.keymaps",
    "harness-decorators.watcher",
  }

  local function leader_maps()
    local maps = {}
    local prefix = (vim.g.mapleader or " ") .. "c"
    for _, mode in ipairs({ "n", "v" }) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if m.lhs:sub(1, #prefix) == prefix then
          maps[#maps + 1] = { mode = mode, lhs = m.lhs, rhs = m.rhs, callback = m.callback, desc = m.desc }
        end
      end
    end
    table.sort(maps, function(a, b)
      return a.mode .. a.lhs < b.mode .. b.lhs
    end)
    return maps
  end

  local function activation_state()
    return {
      current = sw.current(),
      harness = active.get(),
      env = vim.env.NVIM_LLM_HARNESS,
      maps = leader_maps(),
    }
  end

  local function working_pi(hook)
    local adapter = setmetatable({ on_activate = hook or function() end }, {
      __index = saved.modules["harness-decorators.pi"].loaded,
    })
    package.loaded["harness-decorators.pi"] = adapter
    package.preload["harness-decorators.pi"] = function()
      return adapter
    end
  end

  before_each(function()
    -- Load the real adapter once before replacing its loader; the stub inherits its contract.
    require("harness-decorators.pi")
    saved = {
      current = sw.current(),
      harness = active.get(),
      env = vim.env.NVIM_LLM_HARNESS,
      records = state.table,
      stop = watcher.stop,
      start = watcher.start,
      notify = vim.notify,
      modules = {},
    }
    for _, module in ipairs(modules) do
      saved.modules[module] = { loaded = package.loaded[module], preload = package.preload[module] }
    end
    steps, notes = {}, {}
    watcher.stop = function()
      steps[#steps + 1] = "stop"
    end
    watcher.start = function()
      steps[#steps + 1] = "start:" .. active.get()
    end
    vim.notify = function(message, level)
      notes[#notes + 1] = { message = tostring(message), level = level }
    end
    state._reset()
    watcher.set_harness("claude")
    sw.init("claude")
    vim.env.NVIM_LLM_HARNESS = "claude"
    keymaps.clear()
    keymaps.apply(keymaps.build("claude"))
  end)

  after_each(function()
    for _, module in ipairs(modules) do
      local original = saved.modules[module]
      package.loaded[module], package.preload[module] = original.loaded, original.preload
    end
    watcher.stop, watcher.start = saved.stop, saved.start
    vim.notify = saved.notify
    watcher.set_harness(saved.harness)
    sw.init(saved.current)
    state.table = saved.records
    vim.env.NVIM_LLM_HARNESS = saved.env
    keymaps.clear()
    keymaps.apply(keymaps.build(saved.harness))
  end)

  for _, module in ipairs(modules) do
    it(
      "Given a broken "
        .. module
        .. " loader, When pi is activated, Then claude stays active and a later retry succeeds",
      function()
        working_pi()
        local before = activation_state()
        package.loaded[module] = nil
        package.preload[module] = function()
          error("activation import failed: " .. module)
        end
        local ok, err = pcall(sw.activate, "pi")
        assert.is_false(ok, "an activation import failure must raise")
        assert.is_truthy(tostring(err):find("activation import failed", 1, true))
        assert.are.same(before, activation_state(), "failed imports must preserve claude selection, env and mappings")
        assert.are.same({}, steps, "failed imports must not stop or start the watcher")

        local original = saved.modules[module]
        package.loaded[module], package.preload[module] = original.loaded, original.preload
        working_pi()
        sw.activate("pi")
        assert.are.equal("pi", sw.current())
        assert.are.equal("pi", active.get())
        assert.are.equal("pi", vim.env.NVIM_LLM_HARNESS)
        assert.are.equal("pi", vim.fn.maparg("<leader>c", "n", false, true).desc)
        assert.are.same({ "stop", "start:pi" }, steps)
      end
    )
  end

  it(
    "Given keymaps.build throws for pi, When pi is activated, Then claude stays active with its maps and a later retry succeeds",
    function()
      working_pi()
      local before = activation_state()
      local orig_build = keymaps.build
      keymaps.build = function(h)
        if h == "pi" then
          error("keymaps build failed")
        end
        return orig_build(h)
      end
      local ok, err = pcall(sw.activate, "pi")
      keymaps.build = orig_build
      assert.is_false(ok, "a keymaps build failure must raise")
      assert.is_truthy(tostring(err):find("keymaps build failed", 1, true))
      assert.are.same(before, activation_state(), "a failed build must preserve claude selection, env and mappings")
      assert.are.same({}, steps, "a failed build must not stop or start the watcher")

      sw.activate("pi")
      assert.are.equal("pi", sw.current())
      assert.are.same({ "stop", "start:pi" }, steps)
    end
  )

  it(
    "Given the watcher restart throws, When pi is activated, Then the hook and env still ran and one WARN names the watcher",
    function()
      local hook_ran = false
      working_pi(function()
        hook_ran = true
      end)
      watcher.stop = function()
        error("watcher stop failed")
      end
      local orig_log = utils.log
      local logged = {}
      utils.log = function(msg, level)
        logged[#logged + 1] = { msg = msg, level = level }
      end
      local ok, err = pcall(sw.activate, "pi")
      utils.log = orig_log
      assert(ok, err)
      assert.is_true(hook_ran)
      assert.are.equal("pi", vim.env.NVIM_LLM_HARNESS)
      assert.are.equal("pi", sw.current())
      local warns = vim.tbl_filter(function(l)
        return l.level == vim.log.levels.WARN and l.msg:find("activate: watcher failed", 1, true) ~= nil
      end, logged)
      assert.are.equal(1, #warns)
      assert.truthy(warns[1].msg:find("watcher stop failed", 1, true))
    end
  )

  it(
    "Given a throwing activation hook, When pi is activated, Then the watcher is still re-pointed without an escaping error",
    function()
      working_pi(function()
        error("hook cannot install extension")
      end)
      assert.has_no.errors(function()
        sw.activate("pi")
      end)
      assert.are.equal("pi", active.get())
      assert.are.equal("pi", sw.current())
      assert.are.same({ "stop", "start:pi" }, steps)
    end
  )

  it("Given a throwing activation hook, When pi is activated, Then one warning names the harness and error", function()
    local calls = 0
    working_pi(function()
      calls = calls + 1
      error("hook cannot install extension")
    end)
    sw.activate("pi")
    sw.activate("pi")
    assert.are.equal(1, calls, "activating the current harness must not rerun its hook")
    assert.are.equal(1, #notes, "a failed hook must emit one notification")
    assert.are.equal(vim.log.levels.WARN, notes[1].level)
    assert.is_truthy(notes[1].message:find("^pi: "))
    assert.is_truthy(notes[1].message:find("hook cannot install extension", 1, true))
  end)
end)

describe("switch: activation leaves job environment to spawn", function()
  local term = require("harness-decorators.term")
  local state = require("harness-decorators.state")
  local watcher = require("harness-decorators.watcher")
  local snacks = require("snacks.terminal")
  local env_mod = "harness-decorators.copilot.env"
  local saved, counts, steps, outgoing, env

  before_each(function()
    saved = {
      harness = active.get(),
      selection = os.getenv("NVIM_LLM_HARNESS") or vim.NIL,
      records = state.table,
      loaded = package.loaded[env_mod],
      preload = package.preload[env_mod],
      open = snacks.open,
      stop = watcher.stop,
      start = watcher.start,
    }
    counts, steps = { command = 0, prepare = 0, spawn = 0, load = 0 }, {}
    env = {
      command = function()
        counts.command = counts.command + 1
        return "copilot"
      end,
      prepare_env = function()
        counts.prepare = counts.prepare + 1
        return {}
      end,
    }
    package.loaded[env_mod] = env
    package.preload[env_mod] = function()
      counts.load = counts.load + 1
      return env
    end
    snacks.open = function()
      counts.spawn = counts.spawn + 1
      return {
        buf = vim.api.nvim_create_buf(false, true),
        buf_valid = function(self)
          return vim.api.nvim_buf_is_valid(self.buf)
        end,
        show = function() end,
        focus = function() end,
        close = function(self)
          pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
        end,
      }
    end
    state._reset()
    sw.init("claude")
    vim.env.NVIM_LLM_HARNESS = "claude"
    keymaps.clear()
    keymaps.apply(keymaps.build("claude"))
    outgoing = term.open("claude")
    counts.spawn = 0
    watcher.stop = function()
      steps[#steps + 1] = "stop"
    end
    watcher.start = function()
      steps[#steps + 1] = "start:" .. active.get()
    end
  end)

  after_each(function()
    term._reset()
    state.table = saved.records
    package.loaded[env_mod], package.preload[env_mod] = saved.loaded, saved.preload
    snacks.open = saved.open
    watcher.stop, watcher.start = saved.stop, saved.start
    sw.init(saved.harness)
    vim.env.NVIM_LLM_HARNESS = saved.selection ~= vim.NIL and saved.selection or nil
    keymaps.clear()
    keymaps.apply(keymaps.build(saved.harness))
  end)

  for _, action in ipairs({ "activate", "switch" }) do
    it(
      "Given a live outgoing harness, When "
        .. action
        .. " selects Copilot, Then routing changes without preparing env or spawning",
      function()
        sw[action]("copilot")
        assert.are.equal("copilot", sw.current())
        assert.are.equal("copilot", active.get())
        assert.are.equal("copilot", vim.env.NVIM_LLM_HARNESS)
        assert.are.equal("copilot", vim.fn.maparg("<leader>c", "n", false, true).desc)
        assert.are.same({ "stop", "start:copilot" }, steps)
        assert.are.equal(0, counts.command)
        assert.are.equal(0, counts.prepare)
        assert.are.equal(0, counts.spawn)
        assert.is_true(rawequal(outgoing, state.table.claude.inst))
        assert.is_true(vim.api.nvim_buf_is_valid(outgoing.buf))
      end
    )
  end

  it("Given an unloaded env module, When Copilot is activated, Then its env loader is not required", function()
    package.loaded[env_mod] = nil
    package.preload[env_mod] = function()
      counts.load = counts.load + 1
      error("activation must not load a job environment")
    end
    local ok, err = pcall(sw.activate, "copilot")
    assert.is_true(ok, tostring(err))
    assert.are.equal(0, counts.load)
    assert.is_nil(package.loaded[env_mod])
    assert.are.equal("copilot", active.get())
  end)

  it("Given a cached env module table, When switching to Copilot, Then its exact table is retained", function()
    package.preload[env_mod] = function()
      counts.load = counts.load + 1
      return { command = env.command, prepare_env = env.prepare_env }
    end
    sw.switch("copilot")
    assert.is_true(rawequal(env, package.loaded[env_mod]))
    assert.are.equal(0, counts.load)
    assert.are.equal(0, counts.prepare)
    assert.are.equal(0, counts.spawn)
  end)
end)
