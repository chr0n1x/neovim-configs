# PRD: Integration / regression tests for the nvim config

Status: DRAFT
Date: 2026-09-12

## 1. Problem

The config has no runtime test coverage. `make test` runs luacheck, stylua, and a
"load each file with `-u NONE`" check. That last step catches syntax/require errors
only - it loads files in isolation with **no plugins**, so none of the actual
integration behavior is exercised.

Two real regressions slipped through and were only found by hand:

- **A1 (command desync):** `ai-harness.lua` referenced an undefined `command` global,
  so `terminal_cmd` was `nil` at startup and claudecode fell back to its default
  `"claude"`. A fresh `NVIM_LLM_HARNESS=maki nvim` silently ran **claude**. No test
  would have caught this - the file still loaded cleanly under `-u NONE`.
- **Focus restore (`<C-h`):** after a harness swap or certain open sequences, focus did
  not return to the originating buffer. Also invisible to the current check.

Both are *startup / interaction* bugs: "which command actually runs" and "does focus
land where it should." Those are observable in a headless nvim and therefore testable.

## 2. Goals

1. Codify regression tests for the harness layer (command selection, focus restore,
   harness swap) so the above classes of bug fail CI instead of being found by hand.
2. Run **everything** inside the existing `Dockerfile.test` container. Nothing test-
   related runs on the host filesystem: no host nvim, no host busted, no host plenary.
3. Load the **full real config** (option A) so tests exercise the genuine load path,
   not a reduced plugin set.

### Priority (what these tests protect, in order)

Core UI/UX behavior is the target:
1. Neovim starts cleanly with the full real config (no Lua errors on load).
2. Reading files works (open a buffer, filetype detected, content intact).
3. Jumping between buffers works (window focus moves to the intended buffer; no
   duplication).
4. Opening the harness terminal works (`<leader>c` spawns/focuses the float; `<C-h>`
   returns focus to the originating buffer) - the A1 command-selection and
   focus-restore regressions live here.

Code coverage is explicitly out of scope for now (a later concern).

## 3. Non-goals

- Unit-testing individual pure functions (that's a separate, optional effort).
- Testing behavior that requires a live AI API / real model responses.
- GUI/TUI visual assertions. Headless state assertions only.
- Code coverage metrics.
- Making the full plugin stack fast - option A accepts the slower startup.

## 4. Runtime architecture (all in-container)

The container is the only runtime. The host contributes exactly one thing: the mounted
config source.

- **Mount:** `$(pwd)` -> `/nvim-config/nvim` (read-only intent; the config writes its
  own state to the container FS, not the mount).
- **Container-provided:** `nvim` (apk), `busted` (installed at build time), lua tooling.
- **Plugin cache (host-mounted):** `.test-plugins/` -> `/root/.local/share/nvim`.
  `Lazy sync` clones into this directory, so plugin *downloads* are cached on the host
  and reused across runs. This is the one host-side artifact; it holds only git-checkout
  copies of public plugins (never config source or secrets). First run populates it;
  later runs skip the network when `lazy-lock.json` is unchanged. The container still
  owns all *execution* - nvim reads the plugin tree from its own view of the mount, and
  no host process ever touches a plugin.

### Plugin-cache layout

- Host dir: `.test-plugins/` (gitignored). Mount target: `/root/.local/share/nvim`.
- `XDG_DATA_HOME` is left at its default (`~/.local`) so lazy.nvim's standard data
  path lands exactly on the mount - no custom data-dir plumbing.
- Because the mount is shared, a second run reuses the synced tree. To force a clean
  sync (e.g. after `lazy-lock.json` changes), delete `.test-plugins/` first; `make
  test-runtime` does not auto-clean so repeated runs stay fast.

### Container-local ephemeral state (never touches host)

- `~/.cache/nvim`, nvim runtime files, and any per-run scratch live on the container
  filesystem and are discarded when the container exits. Only `.test-plugins/` persists.

### Build-time additions to Dockerfile.test

Current image: `alpine` + bash, neovim, git, make, luacheck, stylua.

Add so the container is self-sufficient for testing:
- `lua5.1`, `luarocks`, plus build deps (`gcc`, `musl-dev`, `lua5.1-dev`) to compile
  busted's C dependencies, then the build deps are removed again.
- `RUN luarocks-5.1 install busted` - a standalone busted in the image (Alpine names the
  binary `luarocks-5.1`, not `luarocks`). Installed at `/usr/local/share/lua/5.1/busted`,
  which nvim's LuaJIT shares, so specs can `require "busted.core"` in-process.

No host tooling is required at runtime; `make ci` only needs podman/docker to run the
container (that is orchestration, not test runtime).

### In-container test entrypoint (two phases) - tests/run.sh

1. **Plugin sync:** snapshot `lazy-lock.json`, run `nvim --headless "+Lazy! sync" +qa`,
   then restore the lock file. The snapshot/restore matters because `Lazy! sync` can bump
   pinned plugin commits as a side effect; a CI run must never change the user's lock file.
2. **Run specs:** `nvim --headless -c "luafile tests/runner.lua"`. runner.lua loads the full
   config, waits for the harness layer to be ready (claudecode + switcher both require), then
   runs busted in-process via the `busted.core` API. Exit code propagates: busted's core
   reports failure counts and runner.lua does `cquit! 1` on any failure.

### Why busted in-process, not the CLI or child-RPC

- Specs need the `vim` API, so they must run inside nvim. Plain lua5.1 (the busted CLI's
  environment) has no sockets/FFI and cannot speak nvim RPC, so a child-nvim-over-RPC design
  is not possible here.
- `require("busted.runner")` parses its file list from the global `arg` table via cliargs,
  which rejects in-process invocation. runner.lua therefore drives `busted.core()` directly:
  create the instance, `require "busted"(busted)` to register executors, load specs with
  `test_file_loader(busted, {"lua"})`, subscribe to failure/error events for reporting, then
  `execute`. Same path the CLI uses, minus arg parsing.

### Headless limitation: snacks terminal mode (affects Tier 2)

The snacks floating terminal cannot stably enter terminal mode in a headless nvim (no UI
backend): `startinsert!` on the float window reports success but the window stays in normal
mode, and snacks' `start_insert` fires in a loop. Consequences for the tests:

- The real AI CLIs are not installed in the container, so `terminal_cmd` points at a missing
  binary; Tier 2 overrides it with `cat` (a stub present in the image) so the float can spawn.
- Feeding `<C-h>` in terminal mode is not reproducible headless. Tier 2 therefore asserts the
  float window opens AND tests the focus *module* (`harness-decorators/focus.lua`:
  capture / jump_to_saved / restore / suppress_next_leave) directly - that module is exactly
  where the regressions lived, and `<C-h>`/`<leader>c` are thin wrappers over it.

### Spec isolation (shared nvim process)

All specs share one nvim process, so module-level state (e.g. `terminal.defaults.
terminal_cmd`) persists across them. helper.lua captures the pristine startup command at
require-time; any spec that overrides it restores to that value in teardown - including when
it is nil - so later specs (especially startup_spec, which asserts the true startup value) see
clean state regardless of execution order.

## 5. Test tiers (as built)

### Tier 1 - Startup / command selection (catches A1-class bugs) - tests/startup_spec.lua

Runs in the one busted nvim (full config already loaded). Asserts:
- `require("claudecode.terminal").defaults.terminal_cmd` equals the string returned by
  `require("harness-decorators.<active_harness>.env")`. **This is the exact A1 assertion.**
  (The command lives in the terminal module's `defaults`, which setup() populates from
  config - not in `state.config.terminal_cmd`.)
- The env command is a non-empty string (not nil).
- Startup produced no Lua errors; claudecode.nvim loaded.

### Tier 2 - Focus restore (catches `<C-h>`/duplication-class bugs) - tests/focus_spec.lua

- Asserts the harness float opens (a terminal-buftype window appears) with a `cat` stub.
- Tests focus.lua directly: capture records a non-terminal window; jump_to_saved returns to
  it; restore bails when the saved buffer is already shown elsewhere (the neo-tree
  duplication regression); suppress_next_leave makes capture a no-op.

### Tier 3 - Harness swap (`<leader>cl`) - tests/swap_spec.lua

- Calls `switch().switch(new_harness)` directly (the same code path the telescope picker
  drives) to a different harness; asserts terminal_cmd re-points to the new harness's env
  value and the switcher records it. Also: switching to the same harness is a no-op, and an
  unknown harness is rejected without changing state.

## 6. Files to add / change

Add:
- `tests/run.sh` - in-container entrypoint (lock-file snapshot, sync, restore, run runner).
- `tests/runner.lua` - loads the full config, waits for readiness, runs busted in-process
  via the `busted.core` API with an inline reporter.
- `tests/helper.lua` - shared helpers: pristine terminal_cmd capture, terminal-window
  detection, scratch buffers, env-command lookup.
- `tests/startup_spec.lua` - Tier 1 (A1 assertion).
- `tests/focus_spec.lua` - Tier 2 (float open + focus module mechanics).
- `tests/swap_spec.lua` - Tier 3 (harness swap).

Change:
- `Dockerfile.test` - add lua5.1, luarocks + build deps; `luarocks-5.1 install busted`.
- `Makefile` - new `test-runtime` target (creates `.test-plugins/`, runs `tests/run.sh`);
  wired into `test:` so lint/style/check run first. `ci` mounts the plugin cache.
- `.gitignore` - ignore `.test-plugins/` (the host-side plugin cache).

Not needed: no changes to `lua/config/lazy.lua` or any config file - option A loads the full
config as-is and every spec resolves its requires against the live instance.

## 7. Definition of done

- `make ci` builds the image and runs all three tiers **inside podman**, with no host-side
  nvim/busted/plenary involved. (Met.)
- Tier 1 fails if the active harness's `terminal_cmd` does not match its env module
  (reproduces A1). Verified: on a tree missing the `local command = require(...)` line, the
  test reports `got "nil"` against the expected command and `make ci` exits non-zero. (Met.)
- Tier 2 fails if the focus module mis-restores or duplicates a buffer. (Met.)
- Tiers pass on a known-good baseline. Verified: with the A1 fix present, all specs pass.
  (Met.)
- Nothing test-related executes on the host filesystem; `lazy-lock.json` is never mutated by
  a run. (Met via lock-file snapshot/restore in run.sh.)

## 8. Decisions (resolved)

- **Plugin sync caching:** the synced plugin tree is cached on the host in `.test-plugins/`
  and mounted at `/root/.local/share/nvim` (section 4). First run downloads; later runs
  reuse it when `lazy-lock.json` is unchanged. No image-layer or named-volume plumbing.
- **LSP/server gating:** if unrelated plugins (java/gopls/mason servers, watchers) make the
  full-config load nondeterministic in the container, gate *those specific* plugins off via
  an env flag (`NVIM_TEST_NO_LSP=1`) for tests only, while keeping the harness layer fully
  loaded. Approved as a fallback; it does not weaken coverage of the code under test. Not yet
  needed - the full stack loads cleanly in the container as built.

## 9. Known limitations / risks

- **Headless terminal mode:** snacks' float cannot enter terminal mode headless (section 4).
  Tier 2 therefore tests the focus module directly rather than feeding `<C-h`. If the key
  wiring itself regresses (e.g. go_back stops calling focus.jump_to_saved), this suite would
  not catch it - only the module-level logic is covered. Acceptable given the headless
  constraint; a TUI-based harness would be needed to cover the full key path.
- **Stub terminal fidelity:** the `cat` stub opens the float and registers snacks' keymaps but
  does not reproduce claude's PTY output. Tier 2 asserts focus mechanics, which do not depend
  on PTY content - acceptable.
- **Full-config flakiness:** option A loads the whole stack. If an unrelated plugin starts
  doing nondeterministic work at load, use the section 8 LSP-gating fallback.

## 10. Interaction tooling: `/nvim-ctrl`

For interactive debugging of a failing spec, run the container with `make dev` (or a manual
podman run) and drive the in-container nvim via its RPC socket rather than restarting by hand.
The automated specs themselves are self-contained (in-process busted) and do not depend on a
manually-held instance.
