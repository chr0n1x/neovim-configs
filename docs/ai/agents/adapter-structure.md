# Harness adapter interface

The generic modules (`watcher`, `jsonl-parser`) are harness-agnostic.
They load the adapter for `NVIM_LLM_HARNESS` (default `claude`) and call only
the functions below. Implementations: `claude/init.lua`, `maki/init.lua`.

## Required

| Function | Returns | Purpose |
|---|---|---|
| `projects_dir()` | `string?` | Directory to watch for session JSONLs. |
| `session_ownership(nvim_cwd, lines, jsonl_path)` | `"match" \| "mismatch" \| "unknown"` | Decide whether a JSONL belongs to this nvim instance. `"unknown"` means no evidence yet; the watcher retries on the next write. |
| `find_reset_command(lines)` | `string?` | Return the reset command text (`"/clear"`, `"/new"`, ...) if any line is one, else nil. Stub: return nil. |
| `is_same_file_reset(cmd)` | `boolean` | True when the reset keeps the same JSONL (only history wiped), false when the session switches files. |
| `parse_tool_result(line, line_number)` | `table?` | Normalize one JSONL line into a change event: `{ file_path, operation, starting_line?, delta?, dedup_key?, source_line?, event_uuid?, event_timestamp?, event_id? }`. Return nil for non-edit lines. Stub: return nil. |

## Optional

| Function | Purpose |
|---|---|
| `session_id(jsonl_path)` | Extract the session id from a JSONL path when it isn't the filename stem. Default (claude/maki): `<session-id>.jsonl` → stem. Copilot overrides it because it stores `<session-id>/events.jsonl`, so the id is the parent dir. Absent hook = filename stem. |
| `flat_sessions_dir = true` (field) | Session JSONLs live at the top level of `projects_dir()`; fswatch watches that dir non-recursively instead of its subdirs. Copilot also sets this: its JSONLs sit one dir down, but macOS FSEvents reports subtree writes, so watching the root catches every (including newly-created) session. |
| `extract_cwd(lines)` | Dialect-specific cwd extraction, used by `session_ownership`. |
| `on_pin(jsonl_path, file_size)` | Called when the watcher first pins a session. Lets the harness recover in-flight edits (maki does, because it writes its JSONL in atomic write+rename bursts) by scanning a tail and calling `watcher.process_recovered_lines(lines, offset)`. Must return the new baseline byte offset (where live scanning resumes); return `file_size` to recover nothing. Absent hook = no recovery, baseline stays at `file_size`. |
| `inotify_events()` | Returns the full inotify event string the watcher subscribes to (e.g. `"close_write,moved_to"`). Absent hook = default `close_write,moved_to`. Maki returns `close_write,moved_to,modify` because it keeps its JSONL open and appends (firing modify, not close_write). |
| `sidecar_name(session_id)` | Returns the sidecar filename (without `.jsonl`) for a session. Used by `sidecar.path()` to build `/tmp/nvim.${USER}/${pid}-<name>.jsonl`. Each harness controls its own naming convention (e.g. `claude-events-session-<id>`, `maki-events-session-<id>`). |
| `score_event(ev)` | Scores a decoded sidecar event by how much diff data it contains (higher = richer). Used by `sidecar.lookup()` to pick the best matching line. |
| `extract_diff(ev)` | Renders a decoded sidecar event as numbered diff text for the previewer. Each harness knows its own dialect (claude: structuredPatch/newString/content; maki: full-file before/after in d.Diff). |

## Normalized change event fields

- `file_path` (string): absolute path of the edited file. Required.
- `operation` (string): `"Edit"` or `"Create"`.
- `starting_line` (number?): 1-based line of the first changed line, positioned in the file as it exists after the edit. Nil for early events that lack line info; consumers must not jump when nil. May point past EOF for pure deletions - consumers clamp to buffer length.
- `dedup_key` (string?): deduplicates repeated autocmds for the same logical edit.
- `delta`, `source_line`, `event_uuid`, `event_timestamp`, `event_id`: optional, harness-specific extras stored in the edit history.

## Invariants the watcher relies on

- Baseline: on first encounter of a JSONL the watcher pins (if ownership is
  `"match"`) and starts reading from the current file size, so preexisting
  content is never replayed. An adapter that implements `on_pin()` may return a
  smaller baseline (after recovering in-flight events), but must never return an
  offset that would cause already-replayed lines to be scanned again on the next
  write.
- Shrinking files are skipped (`file_size <= prev.byte_pos`); an adapter that
  rewrites its own JSONL in place must surface that via `find_reset_command`.
