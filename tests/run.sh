#!/usr/bin/env bash
# Two-phase in-container test entrypoint (see docs/testing-prd.md section 5).
#
#   Phase 1: ensure plugins are synced. `Lazy! sync` clones into the host-mounted
#            plugin cache (/root/.local/share/nvim), so downloads persist across runs.
#   Phase 2: run busted in-process against a headless nvim that has loaded the full
#            real config. The specs drive that live instance directly.
#
# Everything runs inside the container. The host contributes only the mounted config
# source and the plugin cache. Exit code is propagated to `make`.
set -uo pipefail

cd "$(dirname "$0")/.."   # repo root = /nvim-config/nvim

echo "==> [1/2] Lazy sync (plugins cached in /root/.local/share/nvim)"
# NVIM_LAZY_N_LITE is NOT set, so the full plugin stack loads. A fresh cache makes the
# first run slow; subsequent runs reuse it when lazy-lock.json is unchanged.
#
# `Lazy! sync` can bump lazy-lock.json to newer plugin commits as a side effect. That
# would mutate the user's lock file on every CI run, so we snapshot it before sync and
# restore it after - the tests must never change which plugin versions are pinned.
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

echo "==> [2/2] running busted specs (full real config, in-process)"
# The runner waits for LazyDone before running specs, so we don't need a separate sync
# here - the headless nvim loads the already-synced plugin tree.
nvim --headless -n -i NONE -c "luafile tests/runner.lua"
status=$?

echo "==> busted exit: $status"
exit "$status"
