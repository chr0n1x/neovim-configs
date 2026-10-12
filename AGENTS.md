# nvim config - agent rules

This is the **Neovim configuration**: plugins, keymaps, terminal behavior, and
session/possession tracking. The centerpiece is `lua/harness-decorators/`: a set of plugins that
embed AI coding harnesses (maki, claude, copilot, crush, pi) as floats inside nvim, wire up
keymaps to feed file context into the running agent's terminal, and auto-follow the agent's
edits back into the editor. Everything else hangs off that. If you're changing behavior, it
almost always lives in `harness-decorators/`.

## Testing: BDD, red-green, via `make ci`

For **every feature, fix, or behavior change**, work test-first:

1. **Write the spec first.** Given/When/Then. Name the contract explicitly, not the
   symptom. e.g. `Given a buffer opened with a relative name, When <leader>ca, Then the
   harness receives an absolute path` - not "fix relative paths".
2. **Make it red.** Run it against the current code and confirm it FAILS for the reason
   you expect. A green-on-first-run spec proves nothing.
3. **Make it green** with the minimal change.
4. **Prove no regression** with the full suite.

Run specs with:

```
make ci        # podman/docker busted, the ONLY reliable runner
make -C .config/nvim ci   # equivalent when the repo root is the cwd
```

**Do NOT** hand-roll headless `nvim -u init.lua` probes to "confirm" behavior. They hang on
lazy.nvim sync and give you nothing. If you need to see a failing spec, run `make ci` and read
the failure - it will name the exact contract that broke, which is faster than any live
probe.

Live-instance queries (when you must inspect a running nvim): use the `nvim-ctrl` skill
(`nvimx --server <sock> --remote-expr ...`). Never raw msgpack socket framing (the
`--embed` socket does not answer it).

## Architecture map (harness-decorators)

One definition, many callers. Each harness (`maki`, `claude`, `copilot`, `crush`, `pi`) has
its own `<harness>/keymaps.lua` with a per-harness `build_context_text` (formatting differs:
`@`-mention vs bare path, trailing `/` for dirs, `#L` ranges). All of them delegate the actual
work to shared modules - so a "maki bug" is usually a shared-code bug:

- `lua/harness-decorators/context-inject.lua` - the send machinery: `make_add_command`
  (`<leader>ca`, has a `filereadable` gate), `make_tree_add_command` (`<C-t>`, NO gate),
  `send_visual_selection`, `type_into_terminal` (the PTY `chansend` write), and `shorten_path`
  (a thin delegate to utils).
- `lua/harness-decorators/utils.lua` - `shorten_path` (the single path-display definition),
  `get_tree_selection` (delegates to `tree-select.lua`), session/ownership helpers.
- `lua/harness-decorators/tree-select.lua` - reads live neo-tree state; returns file AND dir paths.

**Shared-code callout:** `shorten_path` is used by all five harnesses AND the telescope history
picker. Changing it is a cross-harness behavior change, not a fix for the one harness you're
debugging. Always `make ci` the whole suite, not just the affected spec, and don't scope the
fix to the harness where you saw the symptom.

**Finding the spec:** `tests/` maps ~1:1 to modules by name - `utils_spec.lua` ↔ `utils.lua`,
`tree_selection_spec.lua` ↔ `tree-select.lua`, `add_current_spec.lua` covers all five `*Add`
commands. Search the spec by the module name before writing a new one.

## Layout gotchas

- There is exactly one canonical copy of this config: the repo checkout. If
  `~/.config/nvim` is a symlink to it, `ls -la` on a file inside shows the target's
  real-file mode - do not misread that as a second copy.
- `shorten_path` (utils.lua) path tiers: (0) absolutize a relative input via
  `fnamemodify ":p"`, (1) `~` collapse under `$HOME`, (2) full absolute path. No
  cwd-relative shortening tier. If a path "types wrong", check whether the *input* was
  relative (e.g. `expand("%")` for a relatively-opened buffer) before touching the tiers.
- **Test-cache invariant:** `make ci` mounts the repo as the config dir and `.test-cache/` as
  the data dir. Everything lazy.nvim / mason / possession writes lands in `.test-cache`, never
  the repo. Don't create or commit anything under the repo that looks like lazy/mason/possession
  state (stray `lazy/`, `mason/`, `possession/` dirs) - it belongs in `.test-cache`.
- **No process spawns at startup in the test run.** `make ci` runs a headless nvim that loads
  the full real config; `ai-harness.lua` opens the harness float at startup via
  `open_on_startup`. That path is gated on `vim.fn.has("headless")` so the suite never spawns a
  harness process (a spawned agent PTY never settles and hangs the container). If you add other
  startup work that opens a terminal or external process, guard it the same way.
