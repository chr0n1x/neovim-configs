# AI harness keymaps

`lua/plugins/ai-harness.lua` consolidates the per-harness tables from
`lua/harness-decorators/<harness>/keymaps.lua` into one keys table. The bindings
below are the full set; harnesses wire up a subset and differ in command names.
`claude`, `copilot`, `maki`, and `pi` all wire the context keys (`<leader>ca`,
`<C-t>`, visual `<leader>ca`) via the shared `context-inject` helpers; `crush` has
tree-add only. `<leader>cu` (edit-history picker) exists only where the harness has
live JSONL edit-following - not `crush` or `pi` (yet).

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
