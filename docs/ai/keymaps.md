# AI harness keymaps

`lua/plugins/ai-harness.lua` consolidates the per-harness tables from
`lua/harness-decorators/<harness>/keymaps.lua` into one keys table. The bindings
below are shared by both `claude` and `maki`; only the underlying command names
and descriptions differ.

| Key | Mode | Action |
|---|---|---|
| `<leader>c` | n, x | Focus the harness terminal |
| `<leader>cr` | n | Resume session (`--resume`) |
| `<leader>cc` | n | Continue session (`--continue`) |
| `<leader>cm` | n | Select model |
| `<leader>cu` | n | Telescope picker of the harness's changes |
| `<leader>ca` | n | Add current buffer |
| `<leader>ca` | v | Send visual selection (path + line range) |
| `<C-t>` | tree ft | Add file(s) under cursor / selected in tree |
| `<leader>cda` | n | Accept diff & redraw |
| `<leader>cdd` | n | Deny diff & redraw |

Tree ft = `NvimTree`, `neo-tree`, `oil`, `minifiles`, `netrw`.
