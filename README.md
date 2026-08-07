My NeoVim Configs
====

Where I store my neovim customizations.

This is based on [my neovim template](https://github.com/chr0n1x/neovim-template) - start there or check out [my dotfiles repo](https://github.com/chr0n1x/dotfiles/tree/main/.config) to see how I manage this repo!

I split my neovim configs out into a separate repository to use as a submodule because I have two separate setups:
1. personal machine which is heavily based on the neovim-template linked above, primarily only FOSS plugins
2. work machine, where I have _extra_ configurations and many more work-related dependencies, copilot setup, etc

The goal of having a separate repo is so that I can manage the two configurations which pick & choose various plugins from the base template repo; the two setups are effectively forks of the original template, and constantly evolve based on changes in _each_ setup. The list & rate of changes that each setup goes through became too messy to deal with in my parent dotfiles repo sooooo here we are 😅

## Claude Code Auto-Follow

This config automatically jumps to edited files when Claude Code modifies them on disk.

**How it works:**

1. **`lua/claude-decorators/`** — the entire plugin. Initialized at `LazyDone` via `autocmds.lua`.
2. **`inotify-watcher.lua`** — spawns an `inotifywait -m` process that watches `~/.claude/projects/` for `close_write` events on `.jsonl` files. When a tool result writes a file change to the session log, it fires the `ClaudeAutoFollowEdit` user autocmd with file path and line number.
3. **`edit-jump.lua`** — handles two paths: diff-accepted edits (`ClaudeCodeDiffClosed`) and automode direct edits (the inotify event above). Only jumps when the Claude floating terminal is the focused window — silently skips if focus has moved to a code buffer or elsewhere. When Neovim loses focus entirely (e.g., alt-tab away), the inotify watcher continues running but jumps are still suppressed since the terminal can't be focused.
4. **`jsonl-parser.lua`** — parses the last line of the session JSONL to extract tool result change info (file path, starting line, dedup key).
5. **Lualine integration** — the statusline shows the pinned session name (from `get_pinned_path()`) or a spinner while no session is active.

**Requirements:** `inotifywait` (from `inotify-tools`). Falls back to a no-op polling stub if unavailable.
