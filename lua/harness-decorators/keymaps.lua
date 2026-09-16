-- Consolidated <leader>c* keymap table for the AI harness. Each harness's
-- keymaps.lua (lua/harness-decorators/<harness>/keymaps.lua) returns its own list of
-- lazy.nvim key specs (lhs, action, desc, mode/ft); this module owns the single
-- place where they are wired in: the harness-agnostic <leader>cl switcher and the
-- terminal-open watcher trigger. lua/plugins/ai-harness.lua just registers the
-- result with vim.keymap.set, so there is exactly one keys table for the plugin.
local M = {}

local FT_AUGROUP = "AiHarnessFtKeys"

---The tree filetypes a <C-t> tree-add binding is scoped to. Shared by every per-harness keymaps.lua
--via tree_add_spec, so the set of recognized trees lives in one place (a new tree plugin is added
--here once, not in five files).
local TREE_FTS = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" }

---The <leader>cc "continue last session" spec. Identical across every harness: it drives OUR
--per-harness float (term.open) with --continue, not a claudecode command - so it opens/continues
--THIS harness's terminal. Per-harness keymaps.lua files emit this via M.continue_spec rather than
--re-declaring the callback.
---@param harness string
---@return table spec
function M.continue_spec(harness)
  return {
    "<leader>cc",
    function()
      require("harness-decorators.term").open(harness, { args = "--continue" })
    end,
    desc = "Continue " .. harness:sub(1, 1):upper() .. harness:sub(2),
  }
end

---The <C-t> tree-add spec: ft-scoped to the shared TREE_FTS, running the harness's own <Harness>TreeAdd
--command (registered by context-inject.make_tree_add_command). Per-harness keymaps.lua files emit this
--via M.tree_add_spec rather than re-declaring the lhs/ft/desc shape.
---@param harness string
---@param tree_cmd string the user command, e.g. "ClaudeTreeAdd"
---@return table spec
function M.tree_add_spec(harness, tree_cmd)
  return {
    "<C-t>",
    "<cmd>" .. tree_cmd .. "<cr>",
    desc = "Add file to " .. harness:sub(1, 1):upper() .. harness:sub(2),
    ft = TREE_FTS,
  }
end

---The <leader>cu history-picker spec: opens the telescope-history-picker over this session's recorded
--edits. Identical across every harness that has live edit-following (claude/copilot/maki); crush and pi
--have no JSONL to hang a picker off, so they omit it. Per-harness keymaps.lua files emit this via
--M.history_spec rather than re-declaring the callback.
---@param harness string
---@return table spec
function M.history_spec(harness)
  return {
    "<leader>cu",
    function()
      require("harness-decorators.telescope-history-picker").pick()
    end,
    desc = "View changes made by " .. harness,
    mode = { "n" },
  }
end

---Buffer-local ft-mappings written by M.apply (bufnr -> list of {mode, lhs}).
---Tracked so M.clear can remove them: deleting the FileType augroup alone leaves
---these mappings on already-open buffers, so a stale harness's <C-t> survives a
---switch (e.g. claude -> crush) and keeps firing the old command.
local ft_buf_maps = {}

---The harness-agnostic switcher key. Appended to every harness's spec list so it
---always survives a switch's clear/reapply (see switch.lua).
local function open_agent_picker()
  require("harness-decorators.switch").pick()
end

local function switch_spec()
  return {
    "<leader>cl",
    open_agent_picker,
    desc = "Switch AI harness",
    mode = { "n" },
  }
end

local function agent_picker_spec()
  return {
    "<C-q>",
    open_agent_picker,
    desc = "Switch AI harness",
    mode = { "n" },
  }
end

---Toggle the statusline agent overview on/off. Harness-agnostic, like the switcher: it shows
--every live harness terminal with its work status + label, so it must survive a harness switch.
local function agent_overview_spec()
  return {
    "<leader>co",
    function()
      local ok = pcall(require, "harness-decorators.agent-display")
      if ok then
        require("harness-decorators.agent-display").toggle()
      end
    end,
    desc = "Toggle agent overview",
    mode = { "n" },
  }
end

---The <leader>c key opens (or focuses) the floating terminal. When it creates
---the terminal buffer for the first time, this is also the moment the JSONL
---watcher starts: no terminal, no session, nothing to watch. Requiring the
---module inside the callback keeps this from loading at plugin-spec evaluation
---time (ai-harness.lua is evaluated before plugins are loaded).
local function focus_spec(harness)
  return {
    "<leader>c",
    function()
      local ok = pcall(require, "harness-decorators")
      if ok then
        vim.schedule(function()
          require("harness-decorators").setup_auto_follow()
        end)
      end
      -- Suppress capture for the WinLeave this press triggers, restore the last
      -- normal-mode buffer first (the show below then focuses the terminal window
      -- over it, so the work buffer stays visible underneath), and clear the
      -- suppression once the restore has run.
      local fok, focus = pcall(require, "harness-decorators.focus")
      if fok then
        focus.suppress_next_leave()
        focus.restore()
      end
      -- Table-driven show (Task 6): instead of a single shared terminal handle - which could
      -- re-show a parked buffer from a DIFFERENT harness ("maki shows claude") - ask the unified
      -- park table for the selected harness and show ITS buffer. The table is the source of truth
      -- for which harness is active; term.lua owns each per-harness float.
      local pok, park = pcall(require, "harness-decorators.park")
      if pok then
        park.show_selected()
      end
    end,
    desc = harness,
    mode = { "n", "x" },
  }
end

---Register the given harness's <leader>c* keymaps (plus <leader>cl). Buffer-local
---ft keys are applied to already-open matching buffers and kept current via a
---FileType autocmd; everything else is global.
---@param specs table[] the consolidated spec list from M.build
function M.apply(specs)
  local ft_group = vim.api.nvim_create_augroup(FT_AUGROUP, { clear = true })

  for _, spec in ipairs(specs) do
    if spec.ft then
      local fts = type(spec.ft) == "table" and spec.ft or { spec.ft }
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(fts, vim.bo[buf].filetype) then
          vim.keymap.set(spec.mode or "n", spec[1], spec[2], {
            buffer = buf,
            desc = spec.desc,
            silent = true,
          })
          ft_buf_maps[buf] = ft_buf_maps[buf] or {}
          table.insert(ft_buf_maps[buf], { mode = spec.mode or "n", lhs = spec[1] })
        end
      end
      vim.api.nvim_create_autocmd("FileType", {
        group = ft_group,
        pattern = spec.ft,
        callback = function(args)
          vim.keymap.set(spec.mode or "n", spec[1], spec[2], {
            buffer = args.buf,
            desc = spec.desc,
            silent = true,
          })
        end,
      })
    else
      vim.keymap.set(spec.mode or "n", spec[1], spec[2], {
        desc = spec.desc,
        silent = true,
      })
    end
  end
end

---Remove whatever keymaps the previously-active harness registered: the FileType
---autocmd group AND the buffer-local ft-mappings M.apply wrote directly onto
---already-open buffers. Without the latter, a stale harness's <C-t> survives a
---switch (e.g. claude -> crush) on any still-open tree buffer and keeps firing the
---old command.
function M.clear()
  pcall(vim.api.nvim_del_augroup_by_name, FT_AUGROUP)
  for buf, maps in pairs(ft_buf_maps) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, m in ipairs(maps) do
        -- Unmap only what we set; ignore if the buffer or mapping is already gone.
        pcall(vim.keymap.del, m.mode, m.lhs, { buffer = buf })
      end
    end
  end
  ft_buf_maps = {}
end

---Build the consolidated spec list for a harness: the watcher-triggering <leader>c
---focus entry (always first, so the JSONL watcher starts on open), then the harness's
---own entries, then <leader>cl and <leader>co. Returns the list; registration is
---M.apply's job. The per-harness keymaps files do NOT declare <leader>c themselves -
---focus_spec owns it, so a harness can't shadow the watcher trigger with a stale
---ClaudeCodeFocus binding.
---@param harness string
function M.build(harness)
  local specs = {}
  table.insert(specs, focus_spec(harness))
  package.loaded["harness-decorators." .. harness .. ".keymaps"] = nil
  for _, spec in ipairs(require("harness-decorators." .. harness .. ".keymaps")) do
    table.insert(specs, spec)
  end
  table.insert(specs, switch_spec())
  table.insert(specs, agent_picker_spec())
  table.insert(specs, agent_overview_spec())
  return specs
end

return M
