-- Java support is opt-in on the host: it only loads if a `java` binary is on
-- PATH, and debug support only loads if $JAVA_DEBUG_JAR_PATH points at a jar.
-- This keeps the config portable — a machine without Java gets nothing extra.
--
-- Gotchas:
-- 1. M2E ignores .mvn/maven.config; pass settings.xml via userSettings or classpath is empty.
-- 2. Hover returns nil for ~15-30 min on first launch while jdtls builds its type index.
-- 3. nvim-jdtls auto-loads its own lsp/jdtls.lua (no -data flag) in nvim 0.11+;
--    start_or_attach in the FileType autocmd below overrides it.
-- 4. Private repo creds (e.g. ARTIFACTORY_*) must be in env when nvim starts.

-- Detect whether java is available on PATH (no JVM startup).
local handle = io.popen("which java 2>/dev/null")
local java_path = handle and handle:read("*a")
if handle then
  handle:close()
end
if not java_path or java_path == "" then
  return {}
end

-- Optional debug adapter. Install the jar however you like on the host
-- (Mason, brew, manual) and export JAVA_DEBUG_JAR_PATH to point at it.
local debug_jar = os.getenv("JAVA_DEBUG_JAR_PATH")

-- Build the config jdtls should start with for the current buffer's project.
local function make_jdtls_config()
  -- `root_dir` anchors the project. Order matters: build-tool markers win over
  -- a bare `.git` so nested repos still resolve to the right module.
  local root_dir = vim.fs.root(0, { "gradlew", "mvnw", "pom.xml", ".git" })

  -- One persistent workspace (index/cache) per project, keyed by dir name, so
  -- jdtls doesn't re-index from scratch every launch.
  local project_name = vim.fn.fnamemodify(root_dir or vim.fn.getcwd(), ":p:h:t")
  local workspace_dir = vim.fn.stdpath("cache") .. "/jdtls/" .. project_name

  -- LSP completion capabilities from nvim-cmp, when it's available.
  local ok, cmp = pcall(require, "cmp_nvim_lsp")
  local capabilities = ok and cmp.default_capabilities() or nil

  local bundles = {}
  if debug_jar and debug_jar ~= "" then
    bundles = { debug_jar }
  end

  -- jdtls resolves dependencies with an embedded Maven (M2E) that does NOT read
  -- `.mvn/maven.config`. So when a project pins its settings there (private
  -- repos, mirrors, credentials), jdtls falls back to ~/.m2/settings.xml and
  -- resolves an empty classpath. If the project ships a `.mvn/settings.xml`,
  -- hand it to jdtls explicitly so it resolves like the `mvn` CLI does.
  local maven = {}
  if root_dir then
    local project_settings = root_dir .. "/.mvn/settings.xml"
    if vim.uv.fs_stat(project_settings) then
      maven.userSettings = project_settings
    end
  end

  return {
    name = "jdtls",
    cmd = { "jdtls", "-data", workspace_dir },
    root_dir = root_dir,
    capabilities = capabilities,
    settings = {
      java = {
        configuration = {
          maven = maven,
        },
      },
    },
    init_options = {
      bundles = bundles,
    },
  }
end

local deps = {
  {
    "mfussenegger/nvim-jdtls",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    config = function()
      -- FileType fires once per opened java buffer; start_or_attach reuses the
      -- running server for buffers in the same project.
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "java",
        callback = function()
          require("jdtls").start_or_attach(make_jdtls_config())
        end,
      })
    end,
  },
}

if debug_jar and debug_jar ~= "" then
  table.insert(deps, {
    "rcarriga/nvim-dap-ui",
    dependencies = {
      "mfussenegger/nvim-dap",
      "nvim-neotest/nvim-nio",
    },
    config = function()
      require("dapui").setup()
    end,
  })
end

return deps
