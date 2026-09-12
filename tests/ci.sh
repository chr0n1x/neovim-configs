#!/usr/bin/env bash
# Full CI pass, run entirely inside the test container (Dockerfile.test CMD). The host's
# `make ci` only mounts the codebase + plugin cache and runs this image; everything below
# happens in-container. This is the single definition of "CI" - static analysis first, then
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

echo "==> integration specs (tests/run.sh)"
bash tests/run.sh || { echo "FAIL: integration specs" >&2; exit 1; }

echo "==> CI passed"
