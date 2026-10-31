-- Standardized harness keymap contract. The invariants that must hold for EVERY harness:
--   1. <leader>c is mapped globally (normal mode) - the "jump to terminal" key.
--   2. If a harness declares a <C-t> tree binding, it is scoped to tree filetypes only
--      (NvimTree/neo-tree/oil/minifiles/netrw) and NEVER mapped globally. A global <C-t>
--      would fire outside tree buffers and inject garbage - the class of bug behind
--      "maki: not a readable file: neo-tree".
--   3. If a harness declares a <leader>ca binding, it is mapped globally (normal mode).
--
-- Harnesses differ in how many of these they wire up (crush has tree-add but no
-- add-current-buffer), so we assert each invariant CONDITIONALLY on
-- the harness's own declared keymap table - reading it via keymaps.build() rather than
-- hardcoding a per-harness list. This catches a regression where a harness loses a binding
-- it declares, or accidentally maps <C-t> globally, without forcing every harness to be
-- identical.

local helper = require("tests.helper")
local keymaps = require("harness-decorators.keymaps")
local utils = require("harness-decorators.utils")

-- <leader> is " " (space) in this config, so nvim reports lhs like " c" / " ca", not the
-- literal "<leader>c". Build the expected lhs from the real mapleader.
local LEADER = vim.g.mapleader or " "
local TREE_FTS = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" }

---True if any global (non-buffer) mapping in `mode` has the given lhs (case-insensitive).
---@param mode string
---@param lhs string
---@return boolean
local function has_global_map(mode, lhs)
  local target = lhs:lower()
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if (m.buffer == nil or m.buffer == 0) and m.lhs and m.lhs:lower() == target then
      return true
    end
  end
  return false
end

---The expanded lhs for a <leader>-prefixed key, e.g. LEADER .. "c" gives " c".
---@param suffix string
---@return string
local function leader_key(suffix)
  return LEADER .. suffix
end

---Find the spec in a built keymap list matching an lhs (exact, pre-expansion form like
-- "<leader>c" or "<C-t>"). Returns the spec table or nil.
---@param specs table[]
---@param lhs string
---@return table?
local function find_spec(specs, lhs)
  for _, s in ipairs(specs) do
    if s[1] == lhs then
      return s
    end
  end
  return nil
end

describe("harness keymap contract (all harnesses)", function()
  local original_harness

  setup(function()
    original_harness = helper.active_harness()
    assert.is_not_nil(original_harness, "no active harness to start from")
  end)

  teardown(function()
    if original_harness then
      pcall(require("harness-decorators.switch").switch, original_harness)
    end
  end)

  for _, harness in ipairs(utils.list_harnesses()) do
    describe(("harness: %s"):format(harness), function()
      local specs

      setup(function()
        require("harness-decorators.switch").switch(harness)
        -- The declared (pre-expansion) keymap list for this harness, including the
        -- consolidated <leader>c focus entry and <leader>cl switcher that build() adds.
        specs = keymaps.build(harness)
      end)

      it("<leader>c is mapped globally in normal mode", function()
        assert.is_true(
          has_global_map("n", leader_key("c")),
          ("%s: <leader>c not mapped globally in normal mode"):format(harness)
        )
      end)

      it("<C-q> opens the same agent picker as <leader>cl", function()
        local cl = find_spec(specs, "<leader>cl")
        local cq = find_spec(specs, "<C-q>")
        assert.is_not_nil(cl, ("%s: missing <leader>cl agent picker"):format(harness))
        assert.is_not_nil(cq, ("%s: missing <C-q> agent picker"):format(harness))
        assert.are.same({ "n" }, cq.mode)
        assert.are.equal(cl[2], cq[2])
        assert.is_true(has_global_map("n", "<C-q>"), ("%s: <C-q> not mapped globally in normal mode"):format(harness))
      end)

      it("declared <C-t> tree binding is ft-scoped, never global", function()
        local ct = find_spec(specs, "<C-t>")
        if ct then
          -- Must declare a tree filetype scope.
          assert.is_not_nil(ct.ft, ("%s: <C-t> declared without an ft scope (would map globally)"):format(harness))
          local fts = type(ct.ft) == "table" and ct.ft or { ct.ft }
          for _, ft in ipairs(fts) do
            assert.is_true(
              vim.tbl_contains(TREE_FTS, ft),
              ("%s: <C-t> scoped to non-tree filetype %q"):format(harness, tostring(ft))
            )
          end
        end
        -- Regardless of declaration, <C-t> must never be a global mapping.
        assert.is_false(
          has_global_map("n", "<C-t>"),
          ("%s: <C-t> is mapped globally - should be tree-ft-only"):format(harness)
        )
      end)

      it("declared <leader>ca binding is mapped globally in normal mode", function()
        local ca = find_spec(specs, "<leader>ca")
        if ca then
          assert.is_true(
            has_global_map("n", leader_key("ca")),
            ("%s: declares <leader>ca but it is not mapped globally"):format(harness)
          )
        end
      end)

      it("<C-t> lands on a neo-tree buffer when declared", function()
        local ct = find_spec(specs, "<C-t>")
        if not ct then
          -- Harness doesn't wire tree-add; nothing to verify.
          return
        end
        -- Open a buffer with the neo-tree filetype and confirm the ft-scoped <C-t> lands on
        -- it (the FileType autocmd in keymaps.lua applies ft keys to open matching bufs).
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].filetype = "neo-tree"
        vim.api.nvim_set_current_buf(buf)
        vim.wait(100)

        local found = false
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
          if m.lhs:lower() == "<c-t>" then
            found = true
            break
          end
        end
        assert.is_true(found, ("%s: <C-t> declared but not mapped on a neo-tree buffer"):format(harness))
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end)

      -- Regression (claude): normal-mode <leader>ca must type into OUR per-harness float via
      -- context-inject (our local ClaudeAdd command). claudecode's stock ClaudeCodeAdd routes through
      -- the plugin's own terminal handle and opens a SECOND window in a separate pane, so assert the
      -- action does NOT reference any stock ClaudeCode* command.
      if harness == "claude" then
        it("claude <leader>ca does not run a stock ClaudeCode* command", function()
          local ca = find_spec(specs, "<leader>ca")
          assert.is_not_nil(ca, "claude must declare a normal-mode <leader>ca")
          -- The action is either our local command string or a Lua callback; neither may invoke the
          -- stock claudecode commands.
          local rhs = tostring(ca[2])
          for _, stock in ipairs({ "ClaudeCodeAdd", "ClaudeCodeSend", "ClaudeCodeOpen" }) do
            assert.is_falsy(
              rhs:find(stock, 1, true),
              ("claude <leader>ca must not run the stock %s command - got: %q"):format(stock, rhs)
            )
          end
        end)
      end

      -- Regression (pi): pi's keymaps run on our own term.lua/tree-select and must NOT reference
      -- claudecode.nvim (ClaudeCodeFocus/ClaudeCodeOpen/claudecode.integrations). pi declares both
      -- <leader>ca (PiAdd) and <C-t> (PiTreeAdd); assert their actions are claudecode-free.
      if harness == "pi" then
        it("pi <leader>ca and <C-t> declared and reference no claudecode command", function()
          local ca = find_spec(specs, "<leader>ca")
          local ct = find_spec(specs, "<C-t>")
          assert.is_not_nil(ca, "pi must declare a normal-mode <leader>ca")
          assert.is_not_nil(ct, "pi must declare a <C-t> tree-add")
          for _, spec in ipairs({ ca, ct }) do
            local rhs = tostring(spec[2])
            for _, stock in ipairs({ "ClaudeCode", "claudecode" }) do
              assert.is_falsy(
                rhs:find(stock, 1, true),
                ("pi keymap must not reference %s - got: %q"):format(stock, rhs)
              )
            end
          end
        end)
      end
    end)
  end
end)

-- Per-harness keys and context formats. Every harness is built from one factory, so this pins
-- what each one declares and what each types into its terminal.
describe("harness keymaps: declared keys and context formats", function()
  local ci = require("harness-decorators.context-inject")

  -- The keys each harness declares beyond the shared <leader>c / <leader>cl / <C-q> / <leader>co.
  -- "mode" is "n" unless listed; desc is the which-key text.
  local EXPECTED_KEYS = {
    claude = {
      ["<leader>cc"] = { desc = "Continue Claude" },
      ["<leader>cu"] = { desc = "View changes made by claude" },
      ["<leader>ca"] = { desc = "Add current buffer" },
      ["<leader>ca/v"] = { desc = "Send to Claude" },
      ["<C-t>"] = { desc = "Add file to Claude" },
    },
    copilot = {
      ["<leader>cc"] = { desc = "Continue Copilot" },
      ["<leader>cu"] = { desc = "View changes made by copilot" },
      ["<leader>ca"] = { desc = "Add current buffer" },
      ["<leader>ca/v"] = { desc = "Send selection to Copilot" },
      ["<C-t>"] = { desc = "Add file to Copilot" },
    },
    crush = {
      ["<leader>cc"] = { desc = "Continue Crush" },
      ["<C-t>"] = { desc = "Add file to Crush" },
    },
    maki = {
      ["<leader>cc"] = { desc = "Continue Maki" },
      ["<leader>cu"] = { desc = "View changes made by maki" },
      ["<leader>ca"] = { desc = "Add current buffer" },
      ["<leader>ca/v"] = { desc = "Send selection to Maki" },
      ["<C-t>"] = { desc = "Add file to Maki" },
    },
    pi = {
      ["<leader>cc"] = { desc = "Continue Pi" },
      ["<leader>cr"] = { desc = "Resume Pi" },
      ["<leader>cu"] = { desc = "View changes made by pi" },
      ["<leader>ca"] = { desc = "Add current buffer" },
      ["<leader>ca/v"] = { desc = "Send selection to Pi" },
      ["<C-t>"] = { desc = "Add file to Pi" },
    },
    pig = {
      ["<leader>cc"] = { desc = "Continue Pig" },
      ["<leader>cr"] = { desc = "Resume Pig" },
      ["<leader>ca"] = { desc = "Add current buffer" },
      ["<leader>ca/v"] = { desc = "Send selection to Pig" },
      ["<C-t>"] = { desc = "Add file to Pig" },
    },
  }

  local SHARED = { ["<leader>c"] = true, ["<leader>cl"] = true, ["<C-q>"] = true, ["<leader>co"] = true }

  ---How each harness formats a path: prefix, whether a directory gets a trailing slash, and
  ---whether the trailing space goes in its own write.
  local FORMATS = {
    claude = { prefix = "@", dir_slash = true },
    copilot = { prefix = " @", dir_slash = false, separate_space = true },
    crush = { prefix = "@", dir_slash = true },
    maki = { prefix = "", dir_slash = false },
    pi = { prefix = "@", dir_slash = true },
    pig = { prefix = "@", dir_slash = true },
  }

  local sent, orig_type, orig_tree

  local function expected_text(harness, path, range)
    local fmt = FORMATS[harness]
    local short = utils.shorten_path(path)
    if fmt.dir_slash and vim.fn.isdirectory(path) == 1 and not short:match("/$") then
      short = short .. "/"
    end
    return fmt.prefix .. short .. (range or "")
  end

  before_each(function()
    sent = {}
    orig_type = ci.type_into_terminal
    orig_tree = utils.get_tree_selection
    ci.type_into_terminal = function(text, opts, harness)
      table.insert(sent, { text = text, opts = opts, harness = harness })
      return 1
    end
  end)

  after_each(function()
    ci.type_into_terminal = orig_type
    utils.get_tree_selection = orig_tree
  end)

  it("every harness in the roster has a keys table and a format", function()
    local function sorted_keys(t)
      local k = vim.tbl_keys(t)
      table.sort(k)
      return k
    end
    assert.are.same(sorted_keys(EXPECTED_KEYS), utils.list_harnesses())
    assert.are.same(sorted_keys(FORMATS), utils.list_harnesses())
  end)

  for _, harness in ipairs(utils.list_harnesses()) do
    describe(("harness: %s"):format(harness), function()
      local Cmd = utils.capitalize(harness)
      local file, dir

      before_each(function()
        file = vim.fn.tempname()
        vim.fn.writefile({ "x" }, file)
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir)
      end)

      after_each(function()
        local buf = vim.fn.bufnr(file)
        if buf ~= -1 then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        vim.fn.delete(file)
        vim.fn.delete(dir, "d")
      end)

      it("declares exactly its own keys, modes and descriptions", function()
        local got = {}
        for _, spec in ipairs(keymaps.build(harness)) do
          if not SHARED[spec[1]] then
            local mode = spec.mode
            local key = spec[1] .. ((mode == "v" or (type(mode) == "table" and mode[1] == "v")) and "/v" or "")
            assert.is_nil(got[key], ("%s: %s declared twice"):format(harness, key))
            got[key] = { desc = spec.desc }
          end
        end
        assert.are.same(EXPECTED_KEYS[harness], got)
      end)

      it("<C-t> tree-add types each selected path, newline-separated, in the harness format", function()
        keymaps.build(harness)
        utils.get_tree_selection = function()
          return { file, dir }
        end
        vim.cmd(Cmd .. "TreeAdd")
        local texts = vim.tbl_map(function(s)
          return s.text
        end, sent)
        assert.are.same({ expected_text(harness, file), "\n", expected_text(harness, dir) }, texts)
        for _, s in ipairs(sent) do
          assert.are.equal(harness, s.harness)
        end
      end)

      if EXPECTED_KEYS[harness]["<leader>ca"] then
        it("Add types the path with its #L range in the harness format", function()
          keymaps.build(harness)
          vim.cmd(("%sAdd %s 3 5"):format(Cmd, vim.fn.fnameescape(file)))
          vim.cmd(("%sAdd %s 4 4"):format(Cmd, vim.fn.fnameescape(file)))
          vim.cmd(("%sAdd %s"):format(Cmd, vim.fn.fnameescape(file)))
          local texts = vim.tbl_map(function(s)
            return s.text
          end, sent)
          assert.are.same({
            expected_text(harness, file, "#L3-5"),
            expected_text(harness, file, "#L4"),
            expected_text(harness, file),
          }, texts)
          assert.are.equal(harness, sent[1].harness)
          assert.are.equal(FORMATS[harness].separate_space or false, (sent[1].opts or {}).separate_space or false)
        end)

        it("the visual-mode key sends the buffer path in the harness format when not in visual mode", function()
          local specs = keymaps.build(harness)
          local cb
          for _, spec in ipairs(specs) do
            if spec[1] == "<leader>ca" and spec.mode == "v" then
              cb = spec[2]
            end
          end
          assert.is_function(cb)
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          cb()
          assert.are.equal(1, #sent)
          assert.are.equal(expected_text(harness, vim.fn.expand("%:p")), sent[1].text)
        end)

        it(
          "Given a visual line selection, When the send key runs, Then it sends this harness's range format",
          function()
            local specs = keymaps.build(harness)
            vim.cmd("edit " .. vim.fn.fnameescape(file))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three", "four" })
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            vim.cmd("normal! Vj")
            for _, spec in ipairs(specs) do
              if spec[1] == "<leader>ca" and spec.mode == "v" then
                spec[2]()
              end
            end
            assert.are.equal(1, #sent)
            assert.are.equal(expected_text(harness, file, "#L2-3"), sent[1].text)
          end
        )
      else
        it("declares no Add command", function()
          keymaps.build(harness)
          assert.are.equal(0, vim.fn.exists(":" .. Cmd .. "Add"))
        end)
      end

      if EXPECTED_KEYS[harness]["<leader>cr"] then
        it("<leader>cr opens the float with --resume", function()
          local term = require("harness-decorators.term")
          local orig_open = term.open
          local got
          term.open = function(h, opts)
            got = { h, opts }
          end
          for _, spec in ipairs(keymaps.build(harness)) do
            if spec[1] == "<leader>cr" then
              spec[2]()
            end
          end
          term.open = orig_open
          assert.are.same({ harness, { args = "--resume" } }, got)
        end)
      end
    end)
  end
end)
