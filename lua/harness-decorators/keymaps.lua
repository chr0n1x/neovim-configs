-- Consolidated <leader>c* keymap table for the AI harness. Each harness's
-- keymaps.lua (lua/harness-decorators/<harness>/keymaps.lua) returns its own list of
-- lazy.nvim key specs (lhs, action, desc, mode/ft); this module owns the single
-- place where they are wired in: the harness-agnostic <leader>cl switcher and the
-- terminal-open watcher trigger. lua/plugins/ai-harness.lua just registers the
-- result with vim.keymap.set, so there is exactly one keys table for the plugin.
local M = {}

local this_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local FT_AUGROUP = "AiHarnessFtKeys"

---Buffer-local ft-mappings written by M.apply (bufnr -> list of {mode, lhs}).
---Tracked so M.clear can remove them: deleting the FileType augroup alone leaves
---these mappings on already-open buffers, so a stale harness's <C-t> survives a
---switch (e.g. claude -> crush) and keeps firing the old command.
local ft_buf_maps = {}

---The harness-agnostic switcher key. Appended to every harness's spec list so it
---always survives a switch's clear/reapply (see switch.lua).
local function switch_spec()
  return {
    "<leader>cl",
    function()
      require("harness-decorators.switch").pick()
    end,
    desc = "Switch AI harness",
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
      -- Table-driven show (Task 6): instead of ClaudeCodeFocus - which routes through
      -- claudecode's single terminal handle and could re-show a parked buffer from a
      -- DIFFERENT harness ("maki shows claude") - ask the unified park table for the
      -- selected harness and show ITS buffer. The table is the source of truth for which
      -- harness is active; claudecode still does the actual window show/hide.
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

---Build the consolidated spec list for a harness: its own entries (with the
---<leader>c focus entry replaced by the watcher-triggering version), plus
---<leader>cl. Returns the list; registration is M.apply's job.
---@param harness string
function M.build(harness)
  local specs = {}
  package.loaded["harness-decorators." .. harness .. ".keymaps"] = nil
  for _, spec in ipairs(require("harness-decorators." .. harness .. ".keymaps")) do
    if spec[1] == "<leader>c" and not spec.ft then
      table.insert(specs, focus_spec(harness))
    else
      table.insert(specs, spec)
    end
  end
  table.insert(specs, switch_spec())
  return specs
end

---List sibling directories that look like a harness (env.lua + keymaps.lua).
---@return string[]
function M.list_harnesses()
  local found = {}
  local fd = vim.uv.fs_scandir(this_dir)
  if fd then
    while true do
      local name, ftype = vim.uv.fs_scandir_next(fd)
      if not name then
        break
      end
      if ftype == "directory" then
        local dir = this_dir .. "/" .. name
        if vim.uv.fs_stat(dir .. "/env.lua") and vim.uv.fs_stat(dir .. "/keymaps.lua") then
          table.insert(found, name)
        end
      end
    end
  end
  table.sort(found)
  return found
end

return M
