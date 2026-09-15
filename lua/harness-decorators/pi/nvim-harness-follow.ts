// pi extension: session-state + edit-following bridge to a parent Neovim.
//
// Ships inside the nvim config repo (lua/harness-decorators/pi/) and is symlinked into pi's
// global extensions dir by the pi adapter's on_activate (see pi/follow.lua ensure()). When pi
// runs inside nvim's floating terminal, nvim sets $NVIM to its RPC socket in the job env; this
// extension is the only place that can know pi's identity/status (it runs in-process, and macOS
// won't expose the process env to nvim). It pushes two kinds of events to that nvim, both into
// pi/follow.lua's ingest():
//   * "session" - on session_start / agent_start / agent_settled / session_shutdown: the real
//                 session id + working/idle status + cwd, so pi/state.lua reports accurate
//                 status and a uuid label instead of guessing from file mtimes.
//   * "edit"    - on edit/write tool results: path + numbered diff, so nvim fires HarnessEdit
//                 and edit-jump lands on the changed file:line.
//
// Transport: base64(JSON) passed as a vimscript string literal to luaeval via
// `nvim --server $NVIM --remote-expr`. base64 has no quotes/newlines and execFile passes argv
// without a shell, so there is nothing to escape. Fails soft: no $NVIM -> the factory registers
// nothing; any RPC error is swallowed (edit-following must never disrupt pi).

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { resolve } from "node:path";

const NVIM = process.env.NVIM;
const EDIT_TOOLS = new Set(["edit", "write", "multiedit"]);

function push(obj: Record<string, unknown>): void {
  if (!NVIM) return;
  const b64 = Buffer.from(JSON.stringify(obj), "utf8").toString("base64");
  const expr = `luaeval("require('harness-decorators.pi.follow').ingest(_A)", '${b64}')`;
  execFile("nvim", ["--server", NVIM, "--remote-expr", expr], () => {
    // best-effort: ignore RPC failures (nvim gone, socket stale, etc.)
  });
}

export default function (pi: ExtensionAPI) {
  // Only meaningful inside an nvim-spawned terminal. Standalone pi -> no-op.
  if (!NVIM) return;

  const sessionEvent = (
    ctx: ExtensionContext,
    status: "working" | "idle",
    phase: string,
  ): void => {
    push({
      kind: "session",
      session_id: ctx.sessionManager.getSessionId(),
      session_file: ctx.sessionManager.getSessionFile() ?? undefined,
      cwd: ctx.cwd,
      status,
      phase,
    });
  };

  pi.on("session_start", (_event, ctx) => sessionEvent(ctx, "idle", "start"));
  pi.on("agent_start", (_event, ctx) => sessionEvent(ctx, "working", "status"));
  pi.on("agent_settled", (_event, ctx) => sessionEvent(ctx, "idle", "status"));
  pi.on("session_shutdown", (_event, ctx) => {
    push({
      kind: "session",
      phase: "shutdown",
      session_id: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
    });
  });

  pi.on("tool_result", (event, ctx) => {
    if (event.isError) return;
    if (!EDIT_TOOLS.has(event.toolName)) return;

    const input = (event.input ?? {}) as { path?: string };
    if (!input.path) return;

    const details = (event.details ?? {}) as { diff?: string };
    push({
      kind: "edit",
      session_id: ctx.sessionManager.getSessionId(),
      file_path: resolve(process.cwd(), input.path),
      operation: event.toolName === "write" ? "Write" : "Edit",
      diff: details.diff,
    });
  });
}
