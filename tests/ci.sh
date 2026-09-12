#!/usr/bin/env bash
# Full CI pass, run entirely inside the test container (Dockerfile.test CMD). The host's
# `make ci` only mounts the codebase + plugin cache and runs this image; everything below
# happens in-container. This is the single definition of "CI": static analysis first, then
# the integration specs. Any non-zero step aborts the rest and fails the run.
set -uo pipefail

cd "$(dirname "$0")/.."   # repo root = /nvim-config/nvim

echo "==> lint (luacheck)"
luacheck lua/ --no-global || { echo "FAIL: luacheck" >&2; exit 1; }

echo "==> style (stylua check)"
stylua --check lua/ || { echo "FAIL: stylua" >&2; exit 1; }

# Load each lua file to catch syntax and require errors. -u NONE skips the full config so no
# plugin sync is needed here; lua/ is prepended to package.path so modules can require each
# other. Files that depend on lazy-loaded plugins are skipped (they load in the integration
# phase against the real synced tree).
SKIP_CHECK="lua/util/task_notifications.lua lua/config/lazy.lua"
echo "==> check (load every lua file)"
while IFS= read -r f; do
  if echo "$SKIP_CHECK" | grep -qF "$f"; then continue; fi
  NVIM_LOG_FILE=/dev/null nvim --headless -u NONE \
    -c "set noswapfile" \
    -c "lua package.path = package.path .. ';' .. vim.fn.expand('$PWD/lua/?.lua')" \
    -c "lua dofile(vim.fn.expand('${f}'))" \
    -c "qa!" 2>/dev/null || { echo "FAIL: $f" >&2; exit 1; }
done < <(find lua/ -name '*.lua')

# --- Integration specs -----------------------------------------------------------
# Phase 1: ensure plugins are synced. `Lazy! sync` clones into the host-mounted plugin cache
# (/root/.local/share/nvim), so downloads persist across runs. NVIM_LAZY_N_LITE is NOT set, so
# the full plugin stack loads. A fresh cache makes the first run slow; subsequent runs reuse it
# when lazy-lock.json is unchanged.
#
# `Lazy! sync` can bump lazy-lock.json to newer plugin commits as a side effect. That would
# mutate the user's lock file on every CI run, so we snapshot it before sync and restore it
# after - the tests must never change which plugin versions are pinned.
echo "==> [specs 1/2] Lazy sync (plugins cached in /root/.local/share/nvim)"
LOCK="lazy-lock.json"
if [ -f "$LOCK" ]; then
  cp "$LOCK" /tmp/lazy-lock.test.bak
fi
if ! nvim --headless -n -i NONE "+Lazy! sync" +qa 2>&1 | tail -5; then
  echo "FAIL: Lazy sync did not complete cleanly" >&2
  # Don't hard-fail here: a partial sync may still let the harness layer load. But if
  # claudecode.nvim itself is missing, the specs will fail loudly in phase 2.
  if ! lua5.1 -e 'local s=io.open("/root/.local/share/nvim/lazy/claudecode.nvim"); if not s then os.exit(1) end' 2>/dev/null; then
    echo "FAIL: claudecode.nvim is not present after sync" >&2
    exit 1
  fi
fi
# Restore the lock file so the test run leaves the pinned plugin versions untouched.
if [ -f /tmp/lazy-lock.test.bak ]; then
  cp /tmp/lazy-lock.test.bak "$LOCK"
  rm -f /tmp/lazy-lock.test.bak
fi

echo "==> [specs 2/2] running busted specs (full real config, in-process)"
# The runner waits for the harness layer to load before running specs, so we don't need a
# separate sync here - the headless nvim loads the already-synced plugin tree.
nvim --headless -n -i NONE -c "luafile tests/runner.lua"
status=$?

echo "==> busted exit: $status"
[ "$status" -eq 0 ] || { echo "FAIL: integration specs" >&2; exit 1; }

echo "==> CI passed"
