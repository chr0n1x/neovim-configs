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

# Full CI: build the image if needed, then run it once with the codebase + plugin cache
# mounted. The container runs tests/ci.sh (lint + style + load check + integration specs) -
# a single in-container definition of CI. No nested make; the host only mounts and invokes.
ci:
	@test -x "$$(command -v $(PODMAN))" || { echo "podman not found"; exit 1; }
	@$(PODMAN) images --format '{{.Repository}}:{{.Tag}}' | grep -qF "$(IMAGE_TAG)" || \
		$(PODMAN) build --file $(DOCKERFILE) --tag "$(IMAGE_TAG)" -q .
	@# kill any stuck container from a prior run
	@$(PODMAN) ps -a --filter "ancestor=$(IMAGE_TAG)" --format '{{.ID}}' | xargs -r $(PODMAN) stop 2>/dev/null || true
	@# plugin cache dir must exist on the host before bind-mount (ci.sh mounts it)
	@test -d .test-plugins || mkdir -p .test-plugins
	@$(PODMAN) run --rm \
		-e CLAUDE_MODEL \
		-e ANTHROPIC_BASE_URL \
		-v $$(pwd):/nvim-config/nvim \
		-v $$(pwd)/.test-plugins:/root/.local/share/nvim "$(IMAGE_TAG)"

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
