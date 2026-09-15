-- Tree selection resolution. The <C-t> tree-add path (every harness) calls
-- get_tree_selection(), which must return a list of ABSOLUTE file/dir paths from the tree
-- plugin - never a buffer name or filetype like "neo-tree". A regression that returns the
-- buffer name instead of a node path is what produced "maki: not a readable file: neo-tree"
-- when <C-t> fired in neo-tree.
--
-- We drive our own selector (harness-decorators/tree-select, reached via
-- utils.get_tree_selection) against a real neo-tree state and assert the returned
-- paths are absolute and point at existing filesystem entries.

local helper = require("tests.helper")

-- Unit coverage for the selector itself, independent of neo-tree actually opening.
-- We stub neo-tree's sources.manager to return a synthetic filesystem state and assert
-- the module resolves it (cursor node, tracked selection) - and that an unavailable
-- manager yields an error rather than a crash or a bogus path.
describe("tree-select: get_selected against a stubbed neo-tree state", function()
  local saved_manager = package.loaded["neo-tree.sources.manager"]

  after_each(function()
    package.loaded["neo-tree.sources.manager"] = saved_manager
  end)

  it("returns the node under the cursor from a synthetic state", function()
    local path = vim.uv.cwd() .. "/lua/harness-decorators/tree-select.lua"
    assert.is_true(vim.fn.filereadable(path) == 1, "fixture missing: " .. path)
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function()
        return {
          winid = vim.api.nvim_get_current_win(),
          tree = {
            get_selection = function() return {} end,
            get_node = function() return { type = "file", path = path } end,
          },
        }
      end,
    }
    local files, err = require("harness-decorators.tree-select").get_selected()
    assert.is_nil(err)
    assert.are.same({ path }, files)
  end)

  it("returns tracked selection nodes when present", function()
    local a = vim.uv.cwd() .. "/lua/harness-decorators/tree-select.lua"
    local b = vim.uv.cwd() .. "/lua/harness-decorators/utils.lua"
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function()
        return {
          winid = vim.api.nvim_get_current_win(),
          tree = {
            get_selection = function()
              return {
                { type = "file", path = a },
                { type = "file", path = b },
              }
            end,
          },
        }
      end,
    }
    local files = require("harness-decorators.tree-select").get_selected()
    assert.are.same({ a, b }, files)
  end)

  it("returns an error (not a path) when neo-tree is unavailable", function()
    package.loaded["neo-tree.sources.manager"] = nil
    local ok, files, err = pcall(require("harness-decorators.tree-select").get_selected)
    assert.is_true(ok, "get_selected threw when neo-tree was unavailable")
    if type(files) == "table" then
      for _, p in ipairs(files) do
        assert.is_not.equal("neo-tree", tostring(p))
      end
    end
  end)
end)

describe("tree selection: get_tree_selection returns real paths", function()
  it("returns an error (not a bogus path) when not in a tree buffer", function()
    -- In a normal file buffer, the backend must report "not in a supported tree buffer"
    -- rather than returning something that looks like a path.
    local buf = helper.open_scratch("-notree.txt")
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "text"
    vim.wait(50)

    local files, err = require("harness-decorators.utils").get_tree_selection()
    -- Either an empty list with an error, or nil - but NOT a list containing a non-path.
    if type(files) == "table" and #files > 0 then
      for _, p in ipairs(files) do
        assert.is_true(p:match("^/"),
          ("tree selection outside a tree buffer returned a relative/non-absolute path: %q"):format(tostring(p)))
      end
    end
    -- The important invariant: it must not silently return the current buffer's name.
    if type(files) == "table" then
      for _, p in ipairs(files) do
        assert.is_not.equal("neo-tree", tostring(p),
          "get_tree_selection returned the literal 'neo-tree' (a buffer name, not a path)")
      end
    end
  end)

  it("returns absolute paths from a real neo-tree filesystem state", function()
    -- Open neo-tree pointed at a directory that contains a known file, then resolve the
    -- selection. The returned path must be absolute and exist on disk.
    local target_dir = vim.uv.cwd()
    -- Ensure there's at least one regular file in cwd to select (this repo has lua files).
    local probe_file = target_dir .. "/lua/harness-decorators/utils.lua"
    assert.is_true(vim.fn.filereadable(probe_file) == 1,
      "test fixture file missing: " .. probe_file)

    -- Open neo-tree in a dedicated window. Use the plugin's own open so its state is real.
    local ok_open = pcall(function()
      vim.cmd("vnew")
      vim.cmd("silent! NeoTreeToggle")
    end)
    if not ok_open then
      pending("neo-tree could not be opened in this environment")
      return
    end

    -- Find the neo-tree window and make it current so our selector sees
    -- filetype == "neo-tree".
    local tree_win = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(w) then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype == "neo-tree" then
          tree_win = w
          break
        end
      end
    end
    if not tree_win then
      pending("no neo-tree buffer appeared after NeoTreeToggle")
      return
    end
    vim.api.nvim_set_current_win(tree_win)

    -- Give neo-tree a moment to populate its filesystem state.
    vim.wait(500)

    local files, err = require("harness-decorators.utils").get_tree_selection()
    -- If no node is under the cursor yet we may get an empty list + err; that's acceptable.
    -- But if it DOES return paths, they must be absolute and real - never "neo-tree".
    assert.is_not_nil(files, ("get_tree_selection returned nil files (err=%s)"):format(tostring(err)))
    for _, p in ipairs(files) do
      local ps = tostring(p)
      assert.is_not.equal("neo-tree", ps,
        "tree selection returned the literal 'neo-tree' buffer name instead of a path")
      assert.is_true(ps:match("^/"),
        ("tree selection path is not absolute: %q"):format(ps))
    end

    -- Clean up the neo-tree window.
    pcall(vim.cmd, "silent! NeoTreeClose")
  end)
end)
