-- Builds and applies the <leader>c* spec list: shared keys plus the active harness's keymaps.lua.
local utils = require("harness-decorators.utils")

local M = {}

local FT_AUGROUP = "AiHarnessFtKeys"

---Tree filetypes the <C-t> tree-add binding is scoped to.
local TREE_FTS = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" }

---<leader>cc: term.open(harness, --continue).
---@param harness string
---@return table spec
function M.continue_spec(harness)
  return {
    "<leader>cc",
    function()
      require("harness-decorators.term").open(harness, { args = "--continue" })
    end,
    desc = "Continue " .. utils.capitalize(harness),
  }
end

---<C-t>: ft-scoped to TREE_FTS, runs the harness's <Harness>TreeAdd command.
---@param harness string
---@param tree_cmd string the user command, e.g. "ClaudeTreeAdd"
---@return table spec
function M.tree_add_spec(harness, tree_cmd)
  return {
    "<C-t>",
    "<cmd>" .. tree_cmd .. "<cr>",
    desc = "Add file to " .. utils.capitalize(harness),
    ft = TREE_FTS,
  }
end

---<leader>cu: telescope-history-picker over this session's recorded edits. Crush omits it.
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

---Buffer-local ft-mappings written by M.apply (bufnr to list of {mode, lhs}), so M.clear can remove them.
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

---Toggle the statusline agent overview; survives a harness switch.
local function agent_overview_spec()
  return {
    "<leader>co",
    function()
      require("harness-decorators.agent-display").toggle()
    end,
    desc = "Toggle agent overview",
    mode = { "n" },
  }
end

---<leader>c: start following (once), restore the work buffer, show the selected harness.
local function focus_spec(harness)
  return {
    "<leader>c",
    function()
      local harnesses = require("harness-decorators")
      vim.schedule(function()
        harnesses.setup_auto_follow()
      end)
      -- Suppress capture for the WinLeave this press triggers, restore the last
      -- normal-mode buffer first (the show below then focuses the terminal window
      -- over it, so the work buffer stays visible underneath), and clear the
      -- suppression once the restore has run.
      local focus = require("harness-decorators.focus")
      focus.suppress_next_leave()
      focus.restore()
      -- Show the selected harness's own float.
      require("harness-decorators.park").show_selected()
    end,
    desc = harness,
    mode = { "n", "x" },
  }
end

---Register the given harness's <leader>c* keymaps (plus <leader>cl, <C-q> and <leader>co). Buffer-local
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

---Remove the previous harness's keymaps: the FileType autocmd group and the buffer-local
---ft-mappings M.apply wrote onto already-open buffers, so a stale <C-t> does not survive a switch.
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

---focus_spec first, then the harness's keys, then the shared switch/overview keys.
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
