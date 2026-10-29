My NeoVim Configs
====

Where I store my neovim customizations.

This is based on [my neovim template](https://github.com/chr0n1x/neovim-template) - start there or check out [my dotfiles repo](https://github.com/chr0n1x/dotfiles/tree/main/.config) to see how I manage this repo!

I split my neovim configs out into a separate repository to use as a submodule because I have two separate setups:
1. personal machine which is heavily based on the neovim-template linked above, primarily only FOSS plugins
2. work machine, where I have _extra_ configurations and many more work-related dependencies, copilot setup, etc

The goal of having a separate repo is so that I can manage the two configurations which pick & choose various plugins from the base template repo; the two setups are effectively forks of the original template, and constantly evolve based on changes in _each_ setup. The list & rate of changes that each setup goes through became too messy to deal with in my parent dotfiles repo sooooo here we are 😅

## Claude Code Integrations

![claude work history](/docs/assets/claude-work-history.gif?raw=true)

Custom plugin (`lua/harness-decorators/`) that adds:

- **Auto-follow** — automatically jumps to edited files when Claude Code modifies them on disk. Watches for file changes via `inotifywait` (Linux) or `fswatch` (macOS), no manual buffer switching needed.
- **Change history picker** — browse all edits the harness made in the current session (`<leader>cu`). Select an entry to jump to it, with a diff preview _without `git`_. Useful for reviewing changes before commit, or a list of changes that the AI flip-flops between when testing things. Available for claude, copilot, maki, and pi (crush omits it).
- **Lualine status** — shows the pinned session name, the agent's working/idle status, or a spinner while idle in the statusline.
- **Floating terminal** — a [snacks.nvim](https://github.com/folke/snacks.nvim) terminal with animated resize, focus restoration on alt-tab, and a `<leader>c` keymap prefix.
- **Harness roster** — set `NVIM_LLM_HARNESS` to pick which one runs in that float: `claude` (default), `copilot`, `crush`, `maki`, `pi`, or `pig`. They all share the same `<leader>c*` keymaps and auto-follow.

The test suite lives in `tests/` (busted) and runs inside a container via `make ci` from this directory. `AGENTS.md` covers the workflow (BDD, red-green) and the architecture map of `lua/harness-decorators/`.

**Requirements:** `inotifywait` (Linux, from `inotify-tools`) or `fswatch` (macOS, `brew install fswatch`). If neither is installed, live follow is disabled.
