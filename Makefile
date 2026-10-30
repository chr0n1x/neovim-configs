# All targets are relative to this dir (.config/nvim/). Run them from there, or direct
# make at it: `make -C .config/nvim ci`.
NVIM ?= nvim
PODMAN ?= $(shell (command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 && echo podman) || (command -v docker >/dev/null 2>&1 && echo docker) || echo podman)
DOCKERFILE ?= Dockerfile.test
IMAGE_TAG ?= nvim-test

# Full CI is defined in-container by tests/ci.sh (lint + style + load check + integration
# specs). `make ci` below is the single entry point: it mounts the codebase + plugin cache and
# runs the image, which executes ci.sh. There is deliberately no host-side lint/test target -
# everything runs in the container so the host stays clean (docs/testing-prd.md).

# Static analysis with luacheck (lints for unused vars, redefined globals, etc.)
lint:
	@echo "==> luacheck"
	@luacheck lua/ --no-global

# StyLua formatting check (dry-run -- no in-place modification)
# Outputs diff for files that need reformatting but does not fail CI.
# Run `stylua lua/` locally to fix formatting.
style:
	@echo "==> stylua check"
	@stylua --check lua/

fix:
	@stylua lua/

# Full CI: build the image, then run it once with the codebase + test cache mounted. The build
# runs every time so Dockerfile.test changes reach an existing image; an unchanged Dockerfile is
# a layer-cache hit. .dockerignore keeps the build context empty. The container runs tests/ci.sh
# (lint + style + load check + integration specs) - a single in-container definition of CI. No
# nested make; the host only mounts and invokes.
#
# Two mounts only. The repo mount is the nvim config dir (XDG_CONFIG_HOME=/nvim-config).
# The .test-cache mount is the nvim DATA dir (~/.local/share/nvim); XDG_DATA_HOME is NOT
# set, so stdpath("data") resolves to exactly that mount. Every path the config or its
# plugins create - lazy plugin clones, mason packages, possession state - goes through
# stdpath("data") and therefore lands in .test-cache, never the repo. No sub-path mounts:
# mounting at a repo-root path forces podman to create that host dir as the mount
# destination, leaving empty lazy/mason/possession strays in the tree.
ci:
	@test -x "$$(command -v $(PODMAN))" || { echo "podman not found"; exit 1; }
	@$(PODMAN) build --file $(DOCKERFILE) --tag "$(IMAGE_TAG)" -q . >/dev/null
	@# kill any stuck container from a prior run
	@$(PODMAN) ps -a --filter "ancestor=$(IMAGE_TAG)" --format '{{.ID}}' | xargs -r $(PODMAN) stop 2>/dev/null || true
	@# .test-cache must exist on the host before bind-mount (podman creates a missing mount
	@# source as an empty dir, but pre-creating it keeps intent explicit).
	@test -d .test-cache || mkdir -p .test-cache
	@$(PODMAN) run --rm \
		-e CLAUDE_MODEL \
		-e ANTHROPIC_BASE_URL \
		-v $$(pwd):/nvim-config/nvim \
		-v $$(pwd)/.test-cache:/root/.local/share/nvim \
		"$(IMAGE_TAG)"

dev:
	@$(PODMAN) run --rm \
		-e CLAUDE_MODEL \
		-e ANTHROPIC_BASE_URL \
		--entrypoint bash \
		-ti \
		-v $$(pwd):/nvim-config/nvim "$(IMAGE_TAG)"


# actual system clean here
clean:
	rm -rf nvim/plugin ~/.local/share/nvim ~/.config/nvim ~/.cache/nvim
