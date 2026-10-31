-- LSP server config from lua/plugins/lsp.lua. The full real config has already loaded in this nvim
-- (see runner.lua), so vim.lsp.config resolves each server the way it starts for a real buffer.

describe("lsp: server config", function()
  it(
    "Given the config has loaded, When lua_ls's config resolves, Then it has the LuaJIT runtime, the vim global and VIMRUNTIME as a library",
    function()
      local cfg = vim.lsp.config.lua_ls
      assert.is_not_nil(cfg, "no lua_ls config")
      local lua = (cfg.settings or {}).Lua or {}
      assert.are.equal("LuaJIT", (lua.runtime or {}).version, "lua_ls runtime.version")
      assert.is_true(vim.tbl_contains((lua.diagnostics or {}).globals or {}, "vim"), "lua_ls diagnostics.globals")
      assert.is_true(
        vim.tbl_contains((lua.workspace or {}).library or {}, vim.env.VIMRUNTIME),
        "lua_ls workspace.library"
      )
    end
  )

  it("Given the config has loaded, When lua_ls's config resolves, Then it keeps the shared cmp capabilities", function()
    local completion_item =
      vim.tbl_get(vim.lsp.config.lua_ls, "capabilities", "textDocument", "completion", "completionItem")
    assert.is_not_nil(completion_item, "lua_ls has no completion capabilities")
    assert.is_true(completion_item.snippetSupport, "cmp_nvim_lsp's snippet support")
  end)
end)
