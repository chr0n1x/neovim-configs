NVIM ?= nvim
PODMAN ?= podman
DOCKERFILE ?= Dockerfile.test
IMAGE_TAG ?= nvim-test

# Load each lua file to catch syntax and require errors.
# Uses -u NONE to skip full config (no plugin sync). Manually prepends lua/
# to package.path so our own modules can require each other.
# Skips files that depend on lazy-loaded plugins.
SKIP_CHECK := lua/util/task_notifications.lua \
              lua/config/lazy.lua

# Combined test target: static analysis + runtime tests.
# Used as the CMD entrypoint in Dockerfile.test.
test: lint style check

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

# Load each lua file to catch syntax and require errors.
check:
	@for f in $$(find lua/ -name '*.lua'); do \
		if echo "$(SKIP_CHECK)" | grep -qF "$$f"; then continue; fi; \
		echo "check $$f ..."; \
		NVIM_LOG_FILE=/dev/null $(NVIM) --headless -u NONE \
			-c "set noswapfile" \
			-c "lua package.path = package.path .. ';' .. vim.fn.expand('$$(pwd)/lua/?.lua')" \
			-c "lua dofile(vim.fn.expand('$$f'))" \
			-c "qa!" 2>/dev/null || { echo "FAIL: $$f"; exit 1; }; \
	done

ci:
	@test -x "$$(command -v $(PODMAN))" || { echo "podman not found"; exit 1; }
	@$(PODMAN) images --format '{{.Repository}}:{{.Tag}}' | grep -qF "$(IMAGE_TAG)" || \
		$(PODMAN) build --file $(DOCKERFILE) --tag "$(IMAGE_TAG)" -q .
	@# kill any stuck container from a prior run
	@$(PODMAN) ps -a --filter "ancestor=$(IMAGE_TAG)" --format '{{.ID}}' | xargs -r $(PODMAN) stop 2>/dev/null || true
	@$(PODMAN) run --rm \
		-e CLAUDE_MODEL \
		-e ANTHROPIC_BASE_URL \
		-v $$(pwd):/nvim-config/nvim "$(IMAGE_TAG)"

dev:
	@$(PODMAN) run --rm \
		-e CLAUDE_MODEL \
		-e ANTHROPIC_BASE_URL \
		--entrypoint sh \
		-ti \
		-v $$(pwd):/nvim-config/nvim "$(IMAGE_TAG)"


# actual system clean here
clean:
	rm -rf nvim/plugin ~/.local/share/nvim ~/.config/nvim ~/.cache/nvim
