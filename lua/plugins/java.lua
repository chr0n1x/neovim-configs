-- java support is opt-in on the host: it only loads if a `java` binary is on
-- PATH, and debug support only loads if $JAVA_DEBUG_JAR_PATH points at a jar.
-- this keeps the config portable — a machine without java gets nothing extra.
--
-- configuration (set in .envrc or shell profile):
--
--   JAVA_DEBUG_JAR_PATH=/path/to/java-debug-adapter.jar
--     enables DAP debug support. install however you like (mason, brew, build
--     from source) and point the var at whatever path the jar lands at.
--     mason: :MasonInstall java-debug-adapter
--       → ~/.local/share/nvim/mason/packages/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar
--
--   JAVA_INCLUDED_JAR_PATHS="pattern1:pattern2:..."
--     colon-separated glob patterns. each resolved jar is passed as -javaagent
--     to jdtls at startup. use this for compiler-instrumenting libraries that
--     jdtls can't see without agent access (e.g. lombok). kept explicit rather
--     than auto-detected so you always know what's being loaded into the JVM —
--     relevant for audits, SBOMs, and supply-chain hygiene.
--
-- gotchas:
-- 1. M2E ignores .mvn/maven.config; pass settings.xml via userSettings or classpath is empty.
-- 2. hover returns nil for ~15-30 min on first launch while jdtls builds its type index.
-- 3. nvim-jdtls auto-loads its own lsp/jdtls.lua in nvim 0.11+; it starts before
--    our autocmd and wins. disable it explicitly via vim.lsp.enable("jdtls", false).
-- 4. lombok (and other annotation processors): set JAVA_INCLUDED_JAR_PATHS in .envrc
--    as a colon-separated list of glob patterns; each is passed as -javaagent to jdtls.

-- detect whether java is available on PATH (no JVM startup).
local handle = io.popen("which java 2>/dev/null")
local java_path = handle and handle:read("*a")
if handle then
  handle:close()
end
if not java_path or java_path == "" then
  return {}
end

-- optional debug adapter. install the jar however you like on the host
-- (mason, brew, manual) and export JAVA_DEBUG_JAR_PATH to point at it.
local debug_jar = os.getenv("JAVA_DEBUG_JAR_PATH")

-- build the config jdtls should start with for the current buffer's project.
local function make_jdtls_config()
  -- `root_dir` anchors the project. order matters: build-tool markers win over
  -- a bare `.git` so nested repos still resolve to the right module.
  local root_dir = vim.fs.root(0, { "gradlew", "mvnw", "pom.xml", ".git" })

  -- one persistent workspace (index/cache) per project, keyed by dir name, so
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

  -- jdtls resolves dependencies with an embedded maven (M2E) that does NOT read
  -- `.mvn/maven.config`. so when a project pins its settings there (private
  -- repos, mirrors, credentials), jdtls falls back to ~/.m2/settings.xml and
  -- resolves an empty classpath. if the project ships a `.mvn/settings.xml`,
  -- hand it to jdtls explicitly so it resolves like the `mvn` CLI does.
  local maven = {}
  if root_dir then
    local project_settings = root_dir .. "/.mvn/settings.xml"
    if vim.uv.fs_stat(project_settings) then
      maven.userSettings = project_settings
    end
  end

  -- per-project JAR agents (e.g. lombok). patterns are passed directly to the shell
  -- so glob expansion happens there, not via vim.fn.expand (which returns newline-
  -- separated matches that break the io.popen command). sources/javadoc jars are
  -- excluded — they lack the Premain-Class manifest attribute the JVM requires.
  local cmd = { "jdtls", "-data", workspace_dir }
  local jar_paths_env = os.getenv("JAVA_INCLUDED_JAR_PATHS")
  if jar_paths_env and jar_paths_env ~= "" then
    for pattern in jar_paths_env:gmatch("[^:]+") do
      local h = io.popen("ls " .. pattern .. " 2>/dev/null | grep -Ev -- '-sources|-javadoc' | sort -V | tail -1")
      local jar = h and h:read("*a"):gsub("%s+$", "")
      if h then
        h:close()
      end
      if jar and jar ~= "" then
        table.insert(cmd, "--jvm-arg=-javaagent:" .. jar)
      end
    end
  end

  return {
    name = "jdtls",
    cmd = cmd,
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
      -- disable the auto-loaded lsp/jdtls.lua (nvim 0.11+); it starts before our
      -- autocmd and wins, causing our --jvm-arg flags to be ignored entirely.
      vim.lsp.enable("jdtls", false)
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
  local function dap_attach()
    local dap = require("dap")
    local cfg
    for _, c in ipairs(dap.configurations.java or {}) do
      if c.request == "attach" then
        cfg = c
        break
      end
    end
    if not cfg then
      vim.notify("dap: no attach configuration found", vim.log.levels.WARN)
      return
    end
    local tcp = vim.uv.new_tcp()
    tcp:connect(cfg.hostName, cfg.port, function(err)
      tcp:close()
      vim.schedule(function()
        if err then
          vim.notify(
            "dap: nothing listening on "
              .. cfg.hostName
              .. ":"
              .. cfg.port
              .. " — start the server first (<leader>ldr)",
            vim.log.levels.WARN
          )
          return
        end
        local ok, run_err = pcall(dap.run, cfg)
        if not ok then
          vim.notify("dap attach failed: " .. tostring(run_err), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  table.insert(deps, {
    "rcarriga/nvim-dap-ui",
    event = "VimEnter",
    dependencies = {
      "mfussenegger/nvim-dap",
      "nvim-neotest/nvim-nio",
    },
    keys = {
      {
        "<leader>lD",
        function()
          local dap = require("dap")
          if dap.session() then
            require("dapui").toggle()
          else
            dap_attach()
          end
        end,
        desc = "toggle DAP UI",
      },
      {
        "<leader>lde",
        function()
          require("dapui").eval()
        end,
        desc = "eval expression",
        mode = { "n", "v" },
      },
      {
        "<leader>ldf",
        function()
          require("dapui").float_element()
        end,
        desc = "float element picker",
      },
      {
        "<leader>lb",
        function()
          require("dap").toggle_breakpoint()
        end,
        desc = "toggle breakpoint",
      },
      {
        "<leader>ldr",
        function()
          local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
          require("util.procs").toggle(project .. " (java)")
        end,
        desc = "toggle java run output",
      },
    },
    config = function()
      require("dap").listeners.after["event_initialized"]["java_notify"] = function()
        vim.notify("dap attached", vim.log.levels.INFO)
        require("dapui").open()
      end

      -- after all VimEnter handlers (including possession session restore) have run,
      -- auto-attach if session-restored dapui buffers are present.
      vim.schedule(function()
        if require("dap").session() then
          return
        end
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(buf)
          if name:match("^DAP ") or name:match("%[dap%-") then
            dap_attach()
            return
          end
        end
      end)

      local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
      local dap_addr = os.getenv("JAVA_RUN_CMD_DAP") or "localhost:5005"
      require("util.procs").register(project .. " (java)", function()
        return os.getenv("JAVA_RUN_CMD")
      end, {
        desc = "runs $JAVA_RUN_CMD in a dedicated terminal.\n"
          .. "DAP will attach at "
          .. dap_addr
          .. " ($JAVA_RUN_CMD_DAP).",
        on_open = function()
          local dap_attach_ms = 12000
          vim.notify(
            "Attaching DAP to Java server in " .. dap_attach_ms / 1000 .. "sec, enabling mouse for DAP UI ",
            vim.log.levels.INFO
          )
          vim.o.mouse = "a"
          vim.defer_fn(dap_attach, dap_attach_ms)
        end,
      })

      require("dapui").setup()

      local dap = require("dap")
      dap.configurations.java = dap.configurations.java or {}
      local host, port = dap_addr:match("^(.+):(%d+)$")
      if host and port then
        -- vim.uv tcp:connect() requires a numeric IP, not a hostname
        local resolved = host == "localhost" and "127.0.0.1" or host
        table.insert(dap.configurations.java, {
          type = "java",
          request = "attach",
          name = "attach (" .. dap_addr .. ")",
          hostName = resolved,
          port = tonumber(port),
        })
      end
    end,
  })
end

return deps
