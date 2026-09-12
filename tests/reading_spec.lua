-- Reading files. Covers PRD priority #2: opening a buffer must yield the file's actual
-- content with the correct filetype detected. This is basic but load-bearing - if the
-- config broke buffer loading, filetype detection, or line handling, everything else is
-- suspect. Uses real temp files (not just empty buffers) so content round-trip is checked.

local helper = require("tests.helper")

describe("reading: file buffers load correctly", function()
  local files = {}

  teardown(function()
    -- Clean up any scratch windows/buffers we opened.
    for _, buf in ipairs(files) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)

  it("loads a file's content intact", function()
    -- Write a known multi-line file to a temp path, open it, and verify every line.
    local path = vim.fn.tempname() .. "-readme.txt"
    local lines = { "first line", "second line with spaces", "third: colon=equals" }
    vim.fn.writefile(lines, path)

    -- Open in the current window with :edit so nvim reads the file (and fires FileType).
    -- Editing in place (rather than vnew) avoids E36 "not enough room" when earlier specs
    -- have already split the small headless window into many panes.
    vim.cmd("silent! edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    table.insert(files, buf)

    -- Give FileType a tick to fire.
    vim.wait(100)

    local loaded = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same(lines, loaded,
      ("file content did not round-trip:\n  expected %d lines, got %d"):format(
        #lines, #loaded))
  end)

  it("detects filetype for a lua file", function()
    local path = vim.fn.tempname() .. "-sample.lua"
    vim.fn.writefile({ "local x = 1", "return x" }, path)

    vim.cmd("silent! edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    table.insert(files, buf)

    vim.wait(200) -- allow FileType autocmd + treesitter to settle

    local ft = vim.bo[buf].filetype
    assert.are.equal("lua", ft,
      ("expected filetype 'lua', got %q"):format(tostring(ft)))
  end)

  it("detects filetype for a markdown file", function()
    local path = vim.fn.tempname() .. "-notes.md"
    vim.fn.writefile({ "# Heading", "some *text*" }, path)

    vim.cmd("silent! edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    table.insert(files, buf)

    vim.wait(200)

    local ft = vim.bo[buf].filetype
    assert.are.equal("markdown", ft,
      ("expected filetype 'markdown', got %q"):format(tostring(ft)))
  end)
end)
