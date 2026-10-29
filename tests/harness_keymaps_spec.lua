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

---The expanded lhs for a <leader>-prefixed key, e.g. LEADER .. "c" -> " c".
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
      -- context-inject. It used to run claudecode's stock ClaudeCodeAdd, which routed through the
      -- plugin's own terminal handle and opened a SECOND window in a separate pane. Now it runs our
      -- own local ClaudeAdd command - so assert it does NOT reference any stock ClaudeCode* command.
      if harness == "claude" then
        it("claude <leader>ca does not run a stock ClaudeCode* command", function()
          local ca = find_spec(specs, "<leader>ca")
          assert.is_not_nil(ca, "claude must declare a normal-mode <leader>ca")
          -- The action is either our local command string or a Lua callback; neither may invoke the
          -- removed stock plugin commands.
          local rhs = tostring(ca[2])
          for _, stock in ipairs({ "ClaudeCodeAdd", "ClaudeCodeSend", "ClaudeCodeOpen" }) do
            assert.is_falsy(
              rhs:find(stock, 1, true),
              ("claude <leader>ca must not run the stock %s command - got: %q"):format(stock, rhs)
            )
          end
        end)
      end

      -- Regression (pi): the pre-refactor pi keymaps were stashed against claudecode.nvim
      -- (ClaudeCodeFocus/ClaudeCodeOpen/claudecode.integrations). The re-port onto our own
      -- term.lua/tree-select must NOT reintroduce any claudecode reference. pi now declares
      -- both <leader>ca (PiAdd) and <C-t> (PiTreeAdd); assert their actions are claudecode-free.
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
