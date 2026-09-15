local context_inject = require("harness-decorators.context-inject")

describe("visual context selection", function()
  local buf

  setup(function()
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "-visual-selection.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_set_current_buf(buf)
  end)

  teardown(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end)

  local function capture_selection(keys)
    local sent
    local send = context_inject.send_visual_selection(function(text)
      sent = text
    end, function(path, start_line, end_line)
      return string.format("%s#L%d-%d", path, start_line, end_line)
    end)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! " .. keys)
    send()
    return sent
  end

  it("includes the selected line range for linewise visual mode", function()
    local sent = capture_selection("Vj")
    assert.is_truthy(sent:match("#L2%-3$"), sent)
  end)

  it("includes the selected line range for blockwise visual mode", function()
    local sent = capture_selection("\22j")
    assert.is_truthy(sent:match("#L2%-3$"), sent)
  end)

  it("formats Claude selections as an @mention with a line range", function()
    local sent
    package.loaded["harness-decorators.claude.keymaps"] = nil
    local original = context_inject.send_visual_selection
    context_inject.send_visual_selection = function(_, build_context_text)
      return function()
        sent = build_context_text(vim.fn.expand("%:p"), 2, 3)
      end
    end

    local specs = require("harness-decorators.claude.keymaps")
    context_inject.send_visual_selection = original
    for _, spec in ipairs(specs) do
      if spec[1] == "<leader>ca" and spec.mode == "v" then
        spec[2]()
        break
      end
    end

    assert.is_truthy(sent:match("^@.+#L2%-3$"), sent)
  end)

  it("formats Pi selections as an @mention with a line range", function()
    local sent
    package.loaded["harness-decorators.pi.keymaps"] = nil
    local original = context_inject.send_visual_selection
    context_inject.send_visual_selection = function(_, build_context_text)
      return function()
        sent = build_context_text(vim.fn.expand("%:p"), 2, 3)
      end
    end

    local specs = require("harness-decorators.pi.keymaps")
    context_inject.send_visual_selection = original
    for _, spec in ipairs(specs) do
      if spec[1] == "<leader>ca" and spec.mode == "v" then
        spec[2]()
        break
      end
    end

    assert.is_truthy(sent:match("^@.+#L2%-3$"), sent)
  end)
end)
