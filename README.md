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

Custom plugin (`lua/claude-decorators/`) that adds:

- **Auto-follow** — automatically jumps to edited files when Claude Code modifies them on disk. Watches for file changes via `inotifywait` (Linux) or `fswatch` (macOS), no manual buffer switching needed.
- **Change history picker** — browse all edits Claude made in the current session (`<leader>cu`). Select an entry to jump to it, with a diff preview _without `git`_. Useful for reviewing changes before commit, or a list of changes that the AI flip-flops between when testing things.
- **Lualine status** — shows the pinned Claude session name or a spinner while idle in the statusline.
- **Floating terminal** — `claudecode.nvim` wrapper with animated resize, focus restoration on alt-tab, and `<leader>c` keymap prefix.

**Requirements:** `inotifywait` (Linux, from `inotify-tools`) or `fswatch` (macOS, `brew install fswatch`). If neither is installed, live follow is disabled.
